import logging

from django.apps import AppConfig

logger = logging.getLogger(__name__)


class MigrationsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'migrations'

    def ready(self):
        """
        Initialize the migrations app after Django startup.
        
        This hook is called when Django finishes loading all apps and models.
        It's the appropriate place for one-time initialization tasks like
        creating default superadmin users, ensuring database constraints, etc.
        """
        try:
            from .initialization import bootstrap_default_superadmin
            
            # Create default superadmin if none exists (idempotent)
            user, created = bootstrap_default_superadmin()
            if created:
                logger.info(f"[INIT] Default superadmin created: {user.username}")
            
        except Exception as e:
            logger.error(
                f"[INIT] Failed to initialize migrations app: {str(e)}",
                exc_info=True
            )
            # Don't raise - app should still start even if init fails
            # Admin can manually create user via Django shell if needed
