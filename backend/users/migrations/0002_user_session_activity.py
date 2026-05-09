# Generated migration for UserSessionActivity model
# Tracks user session activity for inactivity timeout enforcement

from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('users', '0001_initial'),
    ]

    operations = [
        migrations.CreateModel(
            name='UserSessionActivity',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('last_activity', models.DateTimeField(auto_now=True, help_text='Timestamp of the last authenticated request from this user')),
                ('ip_address', models.CharField(blank=True, default='', help_text='IP address of the client making requests', max_length=45)),
                ('user_agent', models.CharField(blank=True, default='', help_text='User agent string of the client (browser, app, etc.)', max_length=500)),
                ('created_at', models.DateTimeField(auto_now_add=True, help_text='When this session was created (first login)')),
                ('user', models.OneToOneField(help_text='The user associated with this session', on_delete=django.db.models.deletion.CASCADE, related_name='session_activity', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'verbose_name': 'User Session Activity',
                'verbose_name_plural': 'User Session Activities',
            },
        ),
        migrations.AddIndex(
            model_name='usersessionactivity',
            index=models.Index(fields=['user', '-last_activity'], name='users_user_s_user_id_last_idx'),
        ),
        migrations.AddIndex(
            model_name='usersessionactivity',
            index=models.Index(fields=['-last_activity'], name='users_user_s_last_act_idx'),
        ),
    ]
