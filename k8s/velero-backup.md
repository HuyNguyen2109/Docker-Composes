Using this command to initial velero:
```
velero install --provider aws --plugins velero/velero-plugin-for-aws:v1.14.0 --bucket velero --secret-file /mnt/docker-datastore/secrets/velero/s3-credentials --backup-location-config region=auto,s3ForcePathStyle="true",s3Url=https://s3.mcb-homelab.com --use-volume-snapshots=false
```