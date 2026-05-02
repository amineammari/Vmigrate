from django.contrib import admin
from django.urls import include, path
import migrations.views

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/", include("users.urls")),
    path("api/", include("migrations.urls")),
    path("api/health", migrations.views.health, name="api-health"),
]
