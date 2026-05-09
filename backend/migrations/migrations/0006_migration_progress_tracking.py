# Generated migration for job progress tracking and scalability improvements

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('migrations', '0005_openstack_provisioning_run'),
    ]

    operations = [
        migrations.AddField(
            model_name='migrationjob',
            name='progress_percent',
            field=models.IntegerField(default=0, help_text='Overall job progress 0-100%'),
        ),
        migrations.AddField(
            model_name='migrationjob',
            name='current_step',
            field=models.CharField(blank=True, default='', help_text="Current sub-step (e.g., 'downloading_disk', 'converting', 'uploading')", max_length=50),
        ),
        migrations.AddField(
            model_name='migrationjob',
            name='progress_details',
            field=models.JSONField(blank=True, default=dict, help_text='Detailed progress info (affected_disks, current_disk, bytes_transferred, etc.)'),
        ),
        migrations.AddField(
            model_name='migrationjob',
            name='started_at',
            field=models.DateTimeField(blank=True, help_text='When the actual conversion work started (after PENDING)', null=True),
        ),
        migrations.AddField(
            model_name='migrationjob',
            name='completed_at',
            field=models.DateTimeField(blank=True, help_text='When the conversion completed (VERIFIED/FAILED/ROLLED_BACK)', null=True),
        ),
        migrations.AddIndex(
            model_name='migrationjob',
            index=models.Index(fields=['status', '-created_at'], name='migrations__status_created_idx'),
        ),
        migrations.AddIndex(
            model_name='migrationjob',
            index=models.Index(fields=['-progress_percent'], name='migrations__progress_percent_idx'),
        ),
    ]
