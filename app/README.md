# Generic App Chart

This chart deploys one generic application as either a `Deployment` or a `StatefulSet`.
The application workload and its primary `Service` are always named from `app.name`.

## Workload

Enable exactly one workload type:

```yaml
app:
  name: my-app
  containerPort: 8080

deployment:
  enabled: true
  image: ghcr.io/example/my-app:latest

statefulSet:
  enabled: false
```

`deployment.waitFor` and `statefulSet.waitFor` can list service names such as
`postgres`, `mysql`, or `redis`; matching ports are configured under `waitFor.ports`.

## Persistence

When `persistence.enabled` is true, the chart creates a PVC named
`<app.name>-data` unless `persistence.existingClaim` or `persistence.claimName` is set.
The volume is mounted into the app and restic containers at `persistence.mountPath`.

Use `app.volumeMounts` and `app.volumes` for additional custom mounts.

## Data Protection

When enabled, `ghcr.io/infinityvault/restic-backup` is used in three places:

- restore init container on the app pod, skipped when `dataProtection.restore.checkPath` is not empty
- backup CronJob running `restic-backup backup`
- cleanup CronJob running `restic-backup cleanup` with the configured retention flags

Set `dataProtection.repositorySecretName`, `dataProtection.env`, or
`dataProtection.envFrom` to provide restic repository credentials.
