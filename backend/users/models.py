from django.contrib.auth.models import AbstractUser
from django.db import models


class User(AbstractUser):
    class Role(models.TextChoices):
        SUPER_ADMIN = "SUPER_ADMIN", "Super Admin"
        USER = "USER", "User"

    email = models.EmailField(unique=True)
    role = models.CharField(max_length=20, choices=Role.choices, default=Role.USER)
    created_at = models.DateTimeField(auto_now_add=True)

    REQUIRED_FIELDS = ["email"]

    def __str__(self) -> str:
        return f"{self.username} ({self.role})"


class UserSessionActivity(models.Model):
    """
    Track user session activity for inactivity-based session expiration.
    
    Each authenticated user has a session activity record that tracks:
    - When the user was last active (last_activity)
    - Client information (IP address, user agent)
    - Session creation time
    
    This enables 2-hour inactivity timeout while allowing migrations
    to complete even after user logout.
    
    Lifecycle:
    - Created: First authenticated request from a user
    - Updated: On each subsequent authenticated request
    - Expired: Checked on each request; if inactive for 2+ hours, session invalid
    - Cleaned: Can be deleted when user logs out or session expires
    
    Design note: One session per user (not per browser/device).
    For multi-device support, consider adding session_id/token.
    """
    
    user = models.OneToOneField(
        User,
        on_delete=models.CASCADE,
        related_name="session_activity",
        help_text="The user associated with this session"
    )
    last_activity = models.DateTimeField(
        auto_now=True,
        help_text="Timestamp of the last authenticated request from this user"
    )
    ip_address = models.CharField(
        max_length=45,  # IPv6 can be up to 45 chars
        blank=True,
        default="",
        help_text="IP address of the client making requests"
    )
    user_agent = models.CharField(
        max_length=500,
        blank=True,
        default="",
        help_text="User agent string of the client (browser, app, etc.)"
    )
    created_at = models.DateTimeField(
        auto_now_add=True,
        help_text="When this session was created (first login)"
    )
    
    class Meta:
        verbose_name = "User Session Activity"
        verbose_name_plural = "User Session Activities"
        indexes = [
            models.Index(fields=['user', '-last_activity']),
            models.Index(fields=['-last_activity']),
        ]
    
    def __str__(self) -> str:
        return f"{self.user.username} - Last active: {self.last_activity}"

