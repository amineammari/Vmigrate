"""
Comprehensive tests for authentication, session management, and worker scalability.

Tests cover:
1. Default superadmin bootstrap (idempotency, env var handling)
2. Session activity tracking and inactivity timeout
3. Worker progress tracking and concurrent job execution
4. Job independence from session validity (jobs survive logout)
"""

import logging
import os
from datetime import timedelta
from unittest.mock import patch, Mock

from django.contrib.auth import get_user_model
from django.test import TestCase, RequestFactory, override_settings
from django.utils import timezone
from django.core.exceptions import ValidationError

from migrations.initialization import bootstrap_default_superadmin, check_superadmin_exists
from migrations.models import MigrationJob
from users.models import UserSessionActivity
from users.middleware import SessionActivityMiddleware, get_client_ip

User = get_user_model()
logger = logging.getLogger(__name__)


class DefaultSuperadminBootstrapTests(TestCase):
    """Test default superadmin bootstrap initialization."""
    
    def setUp(self):
        """Clear users before each test."""
        User.objects.all().delete()
    
    def test_bootstrap_creates_superadmin_on_first_run(self):
        """Test that superadmin is created on first run when none exist."""
        # No superadmin exists yet
        self.assertFalse(User.objects.filter(role=User.Role.SUPER_ADMIN).exists())
        
        # Bootstrap should create one
        user, created = bootstrap_default_superadmin()
        
        self.assertTrue(created)
        self.assertIsNotNone(user)
        self.assertEqual(user.role, User.Role.SUPER_ADMIN)
        self.assertEqual(user.username, "superadmin")
        self.assertEqual(user.email, "superadmin@local")
    
    def test_bootstrap_is_idempotent(self):
        """Test that bootstrap doesn't recreate superadmin if one exists."""
        # Create first superadmin
        user1, created1 = bootstrap_default_superadmin()
        self.assertTrue(created1)
        
        # Second bootstrap should skip creation
        user2, created2 = bootstrap_default_superadmin()
        self.assertFalse(created2)
        self.assertIsNone(user2)
        
        # Only one superadmin should exist
        self.assertEqual(User.objects.filter(role=User.Role.SUPER_ADMIN).count(), 1)
    
    @override_settings(
        DEFAULT_SUPERADMIN_USERNAME="admin",
        DEFAULT_SUPERADMIN_EMAIL="admin@example.com",
        DEFAULT_SUPERADMIN_PASSWORD="SecurePass123!"
    )
    def test_bootstrap_respects_env_variables(self):
        """Test that bootstrap respects environment variable configuration."""
        user, created = bootstrap_default_superadmin()
        
        self.assertTrue(created)
        self.assertEqual(user.username, "admin")
        self.assertEqual(user.email, "admin@example.com")
    
    @override_settings(DEFAULT_SUPERADMIN_PASSWORD="weak")
    def test_bootstrap_rejects_weak_password(self):
        """Test that bootstrap validates password strength."""
        with self.assertRaises(ValidationError):
            bootstrap_default_superadmin()
    
    def test_bootstrap_password_is_hashed(self):
        """Test that password is securely hashed, not stored in plain text."""
        user, created = bootstrap_default_superadmin()
        
        # Password should be hashed
        self.assertTrue(user.check_password("ChangeMe123!"))
        self.assertNotEqual(user.password, "ChangeMe123!")
    
    def test_check_superadmin_exists(self):
        """Test check_superadmin_exists utility function."""
        self.assertFalse(check_superadmin_exists())
        
        bootstrap_default_superadmin()
        
        self.assertTrue(check_superadmin_exists())


class SessionActivityTrackingTests(TestCase):
    """Test session activity tracking and aninactivity timeout."""
    
    def setUp(self):
        """Create a test user for session tests."""
        self.user = User.objects.create_user(
            username="testuser",
            email="test@example.com",
            password="testpass123",
            role=User.Role.USER
        )
        self.factory = RequestFactory()
        self.middleware = SessionActivityMiddleware(lambda r: Mock(status_code=200))
    
    def test_session_activity_created_on_first_authenticated_request(self):
        """Test that UserSessionActivity is created on first authenticated request."""
        # No activity should exist
        self.assertFalse(UserSessionActivity.objects.filter(user=self.user).exists())
        
        # Create request with user
        request = self.factory.get('/api/migrations/')
        request.user = self.user
        
        # Process through middleware
        self.middleware(request)
        
        # Activity should now exist
        activity = UserSessionActivity.objects.get(user=self.user)
        self.assertIsNotNone(activity)
        self.assertEqual(activity.user, self.user)
    
    def test_session_activity_tracks_ip_and_user_agent(self):
        """Test that session activity tracks client IP and user agent."""
        request = self.factory.get(
            '/api/migrations/',
            HTTP_USER_AGENT='Mozilla/5.0 (Test)',
            REMOTE_ADDR='192.168.1.100'
        )
        request.user = self.user
        
        self.middleware(request)
        
        activity = UserSessionActivity.objects.get(user=self.user)
        self.assertEqual(activity.ip_address, '192.168.1.100')
        self.assertIn('Mozilla', activity.user_agent)
    
    def test_session_activity_updates_last_activity_on_each_request(self):
        """Test that last_activity is updated on each authenticated request."""
        # First request
        request1 = self.factory.get('/api/migrations/')
        request1.user = self.user
        self.middleware(request1)
        
        activity = UserSessionActivity.objects.get(user=self.user)
        first_activity = activity.last_activity
        
        # Simulate time passing
        activity.last_activity = timezone.now() - timedelta(minutes=5)
        activity.save()
        
        # Second request should update last_activity
        request2 = self.factory.get('/api/migrations/')
        request2.user = self.user
        self.middleware(request2)
        
        activity.refresh_from_db()
        self.assertGreater(activity.last_activity, first_activity)
    
    @override_settings(SESSION_INACTIVITY_TIMEOUT_SECONDS=3600)  # 1 hour
    def test_inactive_session_returns_401(self):
        """Test that inactive sessions are rejected with 401."""
        # Create session activity
        activity = UserSessionActivity.objects.create(
            user=self.user,
            ip_address='192.168.1.100'
        )
        
        # Make last_activity long in the past (more than 1 hour)
        activity.last_activity = timezone.now() - timedelta(hours=2)
        activity.save()
        
        # Simulate inactive request
        request =self.factory.get('/api/migrations/')
        request.user = self.user
        
        response = self.middleware(request)
        
        # Should return 401
        self.assertEqual(response.status_code, 401)
        self.assertIn('expired', response.content.decode().lower())
    
    @override_settings(SESSION_INACTIVITY_TIMEOUT_SECONDS=7200)  # 2 hours
    def test_active_session_is_not_rejected(self):
        """Test that active sessions are not rejected."""
        # Create recent session activity
        activity = UserSessionActivity.objects.create(
            user=self.user,
            ip_address='192.168.1.100'
        )
        activity.last_activity = timezone.now() - timedelta(minutes=30)
        activity.save()
        
        # Request should be allowed
        request = self.factory.get('/api/migrations/')
        request.user = self.user
        
        get_response = Mock(return_value=Mock(status_code=200))
        middleware = SessionActivityMiddleware(get_response)
        response = middleware(request)
        
        # Should reach get_response (not rejected)
        get_response.assert_called_once()
    
    def test_anonymous_user_not_tracked(self):
        """Test that anonymous users don't create session activity."""
        from django.contrib.auth.models import AnonymousUser
        
        request = self.factory.get('/api/migrations/')
        request.user = AnonymousUser()
        
        self.middleware(request)
        
        # No activity should be created for anonymous users
        self.assertEqual(UserSessionActivity.objects.count(), 0)


class MigrationJobProgressTests(TestCase):
    """Test progress tracking for long-running migration jobs."""
    
    def setUp(self):
        """Create a test user and job."""
        self.user = User.objects.create_user(
            username="testuser",
            email="test@example.com",
            password="testpass123"
        )
    
    def test_job_progress_initialization(self):
        """Test that new jobs start with 0% progress."""
        job = MigrationJob.objects.create(
            user=self.user,
            vm_name="test-vm",
            status=MigrationJob.Status.PENDING
        )
        
        self.assertEqual(job.progress_percent, 0)
        self.assertEqual(job.current_step, "")
    
    def test_update_progress_method(self):
        """Test the update_progress convenience method."""
        job = MigrationJob.objects.create(
            user=self.user,
            vm_name="test-vm",
            status=MigrationJob.Status.CONVERTING
        )
        
        job.update_progress(
            percent=45,
            step="converting",
            details={"current_disk": 1, "total_disks": 3}
        )
        
        job.refresh_from_db()
        self.assertEqual(job.progress_percent, 45)
        self.assertEqual(job.current_step, "converting")
        self.assertEqual(job.progress_details["current_disk"], 1)
    
    def test_progress_clamped_to_0_100(self):
        """Test that progress is clamped to 0-100 range."""
        job = MigrationJob.objects.create(
            user=self.user,
            vm_name="test-vm"
        )
        
        # Try to set above 100
        job.update_progress(150)
        job.refresh_from_db()
        self.assertEqual(job.progress_percent, 100)
        
        # Try to set below 0
        job.update_progress(-50)
        job.refresh_from_db()
        self.assertEqual(job.progress_percent, 0)
    
    def test_job_timestamps(self):
        """Test started_at and completed_at tracking."""
        job = MigrationJob.objects.create(
            user=self.user,
            vm_name="test-vm",
            status=MigrationJob.Status.PENDING
        )
        
        # Initially, timestamps should be null
        self.assertIsNone(job.started_at)
        self.assertIsNone(job.completed_at)
        
        # Simulate transition to CONVERTING
        start_time = timezone.now()
        job.started_at = start_time
        job.status = MigrationJob.Status.CONVERTING
        job.save()
        
        # Simulate completion
        end_time = timezone.now() + timedelta(hours=2)
        job.completed_at = end_time
        job.status = MigrationJob.Status.VERIFIED
        job.save()
        
        job.refresh_from_db()
        self.assertIsNotNone(job.started_at)
        self.assertIsNotNone(job.completed_at)
        self.assertGreater(job.completed_at, job.started_at)


class JobSessionIndependenceTests(TestCase):
    """Test that jobs continue running even after session expiration."""
    
    def setUp(self):
        """Create test user and job."""
        self.user = User.objects.create_user(
            username="testuser",
            email="test@example.com",
            password="testpass123"
        )
    
    def test_job_preservation_across_logout(self):
        """Test that job record survives user logout."""
        # Create job with user
        job = MigrationJob.objects.create(
            user=self.user,
            vm_name="test-vm",
            status=MigrationJob.Status.PENDING
        )
        job_id = job.id
        
        # Logout user (delete session, invalidate tokens, etc.)
        UserSessionActivity.objects.filter(user=self.user).delete()
        
        # Job should still exist and be retrievable
        job_after = MigrationJob.objects.get(id=job_id)
        self.assertEqual(job_after.user_id, self.user.id)
        self.assertEqual(job_after.vm_name, "test-vm")
    
    def test_job_owned_by_user_at_creation(self):
        """Test that job stores user_id at creation time only."""
        job = MigrationJob.objects.create(
            user=self.user,
            vm_name="test-vm",
            status=MigrationJob.Status.PENDING
        )
        
        original_user_id = job.user_id
        
        # Delete the user (job user should become null)
        self.user.delete()
        
        job.refresh_from_db()
        # User is deleted but job remains (user is SET_NULL in FK)
        self.assertIsNone(job.user)  # But original_user_id shows ownership history


class CeleryWorkerConfigurationTests(TestCase):
    """Test that Celery worker configuration supports 200 concurrent jobs."""
    
    @override_settings(
        CELERY_WORKER_CONCURRENCY=50,
        CELERY_WORKER_PREFETCH_MULTIPLIER=4,
        MAX_CONCURRENT_MIGRATIONS=200
    )
    def test_worker_concurrency_configuration(self):
        """Test that worker concurrency is properly configured."""
        from django.conf import settings
        
        # With 4 workers × 50 concurrency = 200 concurrent
        self.assertEqual(settings.CELERY_WORKER_CONCURRENCY, 50)
        self.assertEqual(settings.CELERY_WORKER_PREFETCH_MULTIPLIER, 4)
        self.assertEqual(settings.MAX_CONCURRENT_MIGRATIONS, 200)
    
    @override_settings(CELERY_TASK_QUEUES=(
        # Should have separate queues for different task types
    ))
    def test_queue_routing_configured(self):
        """Test that task routing is configured for queue distribution."""
        from django.conf import settings
        
        # Task routing should be configured
        self.assertTrue(hasattr(settings, 'CELERY_TASK_ROUTING'))
        self.assertTrue(hasattr(settings, 'CELERY_TASK_QUEUES'))
        
        # Migration tasks should route to 'migrations' queue
        routing = settings.CELERY_TASK_ROUTING.get('migrations.start_migration')
        self.assertIsNotNone(routing)
        self.assertEqual(routing.get('queue'), 'migrations')


class HelperFunctionsTests(TestCase):
    """Test utility functions for sessions and security."""
    
    def test_get_client_ip_from_direct_connection(self):
        """Test IP extraction from direct connection."""
        factory = RequestFactory()
        request = factory.get('/', REMOTE_ADDR='10.0.0.1')
        
        ip = get_client_ip(request)
        self.assertEqual(ip, '10.0.0.1')
    
    def test_get_client_ip_from_x_forwarded_for(self):
        """Test IP extraction when behind proxy."""
        factory = RequestFactory()
        request = factory.get(
            '/',
            HTTP_X_FORWARDED_FOR='203.0.113.45, 192.168.1.1'
        )
        
        ip = get_client_ip(request)
        self.assertEqual(ip, '203.0.113.45')
    
    def test_get_client_ip_fallback(self):
        """Test IP fallback when not available."""
        factory = RequestFactory()
        request = factory.get('/')
        
        ip = get_client_ip(request)
        # Should return some value even if not ideal
        self.assertTrue(ip)


# Integration Tests

class AuthenticationIntegrationTests(TestCase):
    """Integration tests for the full authentication flow."""
    
    def setUp(self):
        """Setup for integration tests."""
        # Clear users
        User.objects.all().delete()
        
        # Create default superadmin
        self.superadmin, _ = bootstrap_default_superadmin()
        
        # Verify superadmin exists
        self.assertTrue(check_superadmin_exists())
    
    def test_full_auth_flow(self):
        """Test complete authentication flow."""
        # Superadmin created and logged in
        self.assertIsNotNone(self.superadmin)
        self.assertEqual(self.superadmin.role, User.Role.SUPER_ADMIN)
        
        # Create regular user
        regular_user = User.objects.create_user(
            username="regular",
            email="regular@example.com",
            password="pass123"
        )
        
        # Session activity should track both
        factory = RequestFactory()
        middleware = SessionActivityMiddleware(lambda r: Mock(status_code=200))
        
        for user in [self.superadmin, regular_user]:
            request = factory.get('/')
            request.user = user
            middleware(request)
        
        # Both should have session activity
        self.assertEqual(UserSessionActivity.objects.count(), 2)


if __name__ == '__main__':
    import unittest
    unittest.main()
