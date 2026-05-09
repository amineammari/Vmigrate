"""
Session activity tracking and inactivity timeout middleware.

This middleware:
1. Tracks user activity (last_activity timestamp) on each authenticated request
2. Enforces 2-hour inactivity timeout
3. Decouple from job execution (jobs continue even after session expires)

Architecture:
- UserSessionActivity model stores last_activity per user
- On each request: check if user inactive for 2+ hours
- If inactive: return 401 (require re-login)
- Only affects HTTP requests, not background Celery jobs
- Migration jobs run independently of session validity
"""

import logging
from datetime import timedelta

from django.conf import settings
from django.http import JsonResponse
from django.utils import timezone
from django.contrib.auth.models import AnonymousUser

logger = logging.getLogger(__name__)


def get_client_ip(request):
    """
    Extract client IP address from request.
    
    Handles X-Forwarded-For header (for proxies/load balancers)
    and direct REMOTE_ADDR.
    """
    x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
    if x_forwarded_for:
        ip = x_forwarded_for.split(',')[0].strip()
    else:
        ip = request.META.get('REMOTE_ADDR', '')
    return ip or "unknown"


def get_user_agent(request):
    """Extract user agent from request headers."""
    return request.META.get('HTTP_USER_AGENT', '')[:500]  # Limit to 500 chars


class SessionActivityMiddleware:
    """
    Middleware to track user session activity and enforce inactivity timeout.
    
    Features:
    - Automatically creates/updates UserSessionActivity on authenticated requests
    - Returns 401 if user has been inactive for 2+ hours
    - Logs session events (creation, inactivity timeout)
    - Non-blocking: exceptions don't stop request processing
    
    Dependencies:
    - Requires UserSessionActivity model in users.models
    - Must run after Django's AuthenticationMiddleware
    - Must run before view processing
    
    Configuration (in settings.py):
    - SESSION_INACTIVITY_TIMEOUT_SECONDS: inactivity window (default: 7200s = 2h)
    
    Usage:
    Add to MIDDLEWARE in settings.py:
        MIDDLEWARE = [
            ...
            'users.middleware.SessionActivityMiddleware',
            ...
        ]
    """
    
    def __init__(self, get_response):
        """Initialize middleware. get_response is the next middleware/view."""
        self.get_response = get_response
        
        # Load configuration with defaults
        self.inactivity_timeout = getattr(
            settings,
            'SESSION_INACTIVITY_TIMEOUT_SECONDS',
            7200  # 2 hours default
        )
    
    def __call__(self, request):
        """
        Process the request and response.
        
        Flow:
        1. If user authenticated: track activity or check inactivity
        2. Call next middleware/view
        3. Return response
        """
        # Only process authenticated requests
        if request.user and request.user.is_authenticated:
            self._update_session_activity(request)
            
            # Check if user is inactive
            if self._is_user_inactive(request.user):
                logger.info(
                    f"User {request.user.username} inactive for {self.inactivity_timeout}s",
                    extra={
                        "event": "session.inactivity_timeout",
                        "user_id": request.user.id,
                        "username": request.user.username,
                        "timeout_seconds": self.inactivity_timeout,
                    }
                )
                
                # Return 401 Unauthorized - session expired
                return JsonResponse(
                    {
                        "detail": "Session expired due to inactivity. Please login again.",
                        "error_code": "session_expired"
                    },
                    status=401
                )
        
        # Continue with next middleware/view
        response = self.get_response(request)
        return response
    
    def _update_session_activity(self, request):
        """
        Create or update UserSessionActivity for the authenticated user.
        
        Non-blocking: silently fails if database is unavailable.
        """
        try:
            from users.models import UserSessionActivity
            
            # Get or create session activity record
            activity, created = UserSessionActivity.objects.get_or_create(
                user=request.user,
                defaults={
                    'ip_address': get_client_ip(request),
                    'user_agent': get_user_agent(request),
                }
            )
            
            # Update activity timestamp and client info
            activity.last_activity = timezone.now()
            activity.ip_address = get_client_ip(request)
            activity.user_agent = get_user_agent(request)
            activity.save(update_fields=['last_activity', 'ip_address', 'user_agent'])
            
            if created:
                logger.info(
                    f"User session created: {request.user.username}",
                    extra={
                        "event": "session.created",
                        "user_id": request.user.id,
                        "username": request.user.username,
                        "ip_address": activity.ip_address,
                    }
                )
        
        except Exception as e:
            # Log error but don't block request
            logger.error(
                f"Failed to update session activity: {str(e)}",
                extra={
                    "event": "session.activity_update_failed",
                    "user_id": request.user.id if request.user else None,
                    "error": str(e),
                },
                exc_info=True
            )
    
    def _is_user_inactive(self, user):
        """
        Check if user has been inactive for longer than the timeout.
        
        Args:
            user: Django User instance (authenticated)
        
        Returns:
            bool: True if user is inactive beyond timeout, False otherwise
        """
        try:
            from users.models import UserSessionActivity
            
            # Get session activity
            activity = UserSessionActivity.objects.get(user=user)
            
            # Calculate inactivity duration
            now = timezone.now()
            inactive_duration = now - activity.last_activity
            timeout_duration = timedelta(seconds=self.inactivity_timeout)
            
            # Check if exceeded timeout
            return inactive_duration > timeout_duration
        
        except Exception as e:
            # If activity record missing or DB error, don't block
            logger.warning(
                f"Failed to check user inactivity: {str(e)}",
                extra={
                    "event": "session.inactivity_check_failed",
                    "user_id": user.id if user else None,
                    "error": str(e),
                }
            )
            return False


class SessionExpirationResponseMiddleware:
    """
    Optional middleware to add Session-Expiration-Time header to responses.
    
    Useful for frontend to know when session will expire and prompt before
    inactivity timeout occurs.
    
    Adds header: X-Session-Expires-At: <ISO timestamp>
    Allows frontend to implement warning: "Your session will expire in X minutes"
    
    Enable by adding to MIDDLEWARE in settings.py:
        'users.middleware.SessionExpirationResponseMiddleware',
    """
    
    def __init__(self, get_response):
        self.get_response = get_response
        self.inactivity_timeout = getattr(
            settings,
            'SESSION_INACTIVITY_TIMEOUT_SECONDS',
            7200
        )
    
    def __call__(self, request):
        response = self.get_response(request)
        
        # Add session expiration time to response headers
        if request.user and request.user.is_authenticated:
            try:
                from users.models import UserSessionActivity
                
                activity = UserSessionActivity.objects.get(user=request.user)
                expires_at = activity.last_activity + timedelta(seconds=self.inactivity_timeout)
                response['X-Session-Expires-At'] = expires_at.isoformat()
            except Exception:
                pass  # Silently fail, don't block response
        
        return response
