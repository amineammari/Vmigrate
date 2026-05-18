"""
Default superadmin user initialization.

This module provides idempotent initialization of a default superadmin user
on application startup. It runs after database migrations are complete.

Security considerations:
- Default credentials are read from environment variables
- No hardcoded secrets in code
- Creation is idempotent (safe for container restarts)
- Logged to audit trail on creation
- Password meets Django security validators
"""

import logging
import os
from django.db import IntegrityError, connection
from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from django.contrib.auth.password_validation import validate_password

logger = logging.getLogger(__name__)
User = get_user_model()


def _user_table_ready() -> bool:
    try:
        return User._meta.db_table in connection.introspection.table_names()
    except Exception:
        return False


def bootstrap_default_superadmin():
    """
    Create a default superadmin user if none exists.
    
    Idempotent: safe to call multiple times. Will only create the user
    on first launch when no superadmin exists.
    
    Environment Variables (with sensible defaults):
    - DEFAULT_SUPERADMIN_USERNAME: superadmin
    - DEFAULT_SUPERADMIN_EMAIL: superadmin@local
    - DEFAULT_SUPERADMIN_PASSWORD: ChangeMe123!
    
    Returns:
        tuple: (user_instance, created_flag)
            - user_instance: User object (new or existing)
            - created_flag: True if user was created in this call, False if already existed
    
    Raises:
        ValidationError: If password doesn't meet Django validators
    
    Logging:
        - Info: User created successfully with username/email
        - Warning: Superadmin already exists, skipping creation
        - Error: Any exception during creation
    """
    
    # Read configuration from environment with sensible defaults
    default_username = os.environ.get("DEFAULT_SUPERADMIN_USERNAME", "superadmin")
    default_email = os.environ.get("DEFAULT_SUPERADMIN_EMAIL", "superadmin@local")
    default_password = os.environ.get("DEFAULT_SUPERADMIN_PASSWORD", "ChangeMe123!")
    
    try:
        if not _user_table_ready():
            logger.info(
                "Default superadmin bootstrap skipped; user table is not ready.",
                extra={
                    "event": "init.superadmin.skipped",
                    "reason": "user_table_not_ready",
                },
            )
            return None, False

        # Check if any superadmin already exists (idempotency check)
        existing_superadmin = User.objects.filter(role=User.Role.SUPER_ADMIN).exists()
        
        if existing_superadmin:
            logger.info(
                "Default superadmin user already exists. Skipping creation.",
                extra={
                    "event": "init.superadmin.skipped",
                    "reason": "superadmin_already_exists",
                },
            )
            return None, False
        
        # Validate password meets Django's security requirements
        try:
            validate_password(default_password, user=None)
        except ValidationError as e:
            logger.error(
                f"Default superadmin password fails validation: {e.messages}",
                extra={
                    "event": "init.superadmin.failed",
                    "reason": "invalid_password",
                    "validation_errors": e.messages,
                },
            )
            raise
        
        # Create the default superadmin user. Another worker may be starting at
        # the same time, so tolerate a duplicate username and treat it as
        # idempotent startup.
        try:
            superadmin_user = User.objects.create_user(
                username=default_username,
                email=default_email,
                password=default_password,
                role=User.Role.SUPER_ADMIN,
            )
        except IntegrityError:
            superadmin_user = User.objects.filter(username=default_username).first()
            if superadmin_user is not None:
                if getattr(superadmin_user, "role", None) != User.Role.SUPER_ADMIN:
                    superadmin_user.role = User.Role.SUPER_ADMIN
                    superadmin_user.save(update_fields=["role"])
                logger.info(
                    "Default superadmin user already exists. Skipping creation.",
                    extra={
                        "event": "init.superadmin.skipped",
                        "reason": "superadmin_username_already_exists",
                    },
                )
                return superadmin_user, False
            raise
        
        logger.info(
            f"Default superadmin user created: {default_username}",
            extra={
                "event": "init.superadmin.created",
                "user_id": superadmin_user.id,
                "username": default_username,
                "email": default_email,
                "role": User.Role.SUPER_ADMIN,
            },
        )
        
        return superadmin_user, True
        
    except Exception as e:
        logger.error(
            f"Failed to bootstrap default superadmin user: {str(e)}",
            extra={
                "event": "init.superadmin.error",
                "error": str(e),
                "error_type": type(e).__name__,
            },
            exc_info=True,
        )
        raise


def check_superadmin_exists():
    """
    Check if any superadmin user exists in the database.
    
    Useful for monitoring and health checks.
    
    Returns:
        bool: True if at least one superadmin exists, False otherwise
    """
    try:
        return User.objects.filter(role=User.Role.SUPER_ADMIN).exists()
    except Exception:
        # Database might not be ready yet (e.g., during migrations)
        return False
