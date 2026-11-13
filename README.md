# Seerr Maintenance & Update Tool

A PowerShell 7 utility for updating an existing Seerr Docker container while preserving its named configuration volume. Read the [troubleshooting and recovery guide](TROUBLESHOOTING.md) before an update.

## What it does

The script validates Docker connectivity, inspects the configured container, confirms that the `seerr-data` named volume is mounted read/write at `/app/config`, checks available disk space, and creates and verifies a timestamped archive of the configuration and database. It then pulls the requested image, saves the previous image ID and inspected container configuration in a maintenance record, and recreates the `seerr` container.

The utility reuses a defined set of settings from Docker inspection, including environment variables, mounts, published ports, restart policy and retry count, network mode and aliases, labels, command, logging options, and selected resource and host settings. Before backup or container changes, it compares unsupported container settings with the current image defaults and checks for non-default host, network, and mount settings it cannot recreate. Unsupported non-default settings stop the operation with the affected setting names. It does **not** preserve every possible Docker option; review the supported-setting lists and `New-RunArguments` before using it with a customized container.

The script does not remove or recreate the `seerr-data` volume, prune Docker resources, or act on other containers. Docker container recreation removes the old container before starting its replacement. If that replacement fails, the maintenance record and backup are intended to support recovery with the rollback procedure below.

## Requirements and defaults

- PowerShell 7
- Docker CLI connected to the intended Docker engine
- The existing container named `seerr`
- The existing `seerr-data` named volume mounted read/write at `/app/config`
- At least 2 GiB free on the backup drive by default

The script defaults to `ghcr.io/seerr-team/seerr:latest`, a 180-second startup timeout, and `http://localhost:5055` for its HTTP check. Parameters can override the container name, image, volume, config path, backup directory, timeout, and minimum free space. The HTTP check URI is currently fixed in the script.

Run the local, Docker-free checks with:

```powershell
pwsh -NoProfile -File .\tests\Update-Seerr.Tests.ps1
```

## Dry run

From this project directory, run:

```powershell
pwsh -NoProfile -File .\Update-Seerr.ps1
```

Dry run is the default. The script inspects Docker and prints the target image, current image ID, volume, backup path, free space, and HTTP check. It does not stop or modify the container, pull an image, or write a backup.

## Apply an update

Run the dry run first, then review its summary. To apply the update:

```powershell
pwsh -NoProfile -File .\Update-Seerr.ps1 -Apply
```

The script stops Seerr, if it was running, to copy a consistent configuration and SQLite database. It creates a `.tar.gz` archive and lists its contents to check that the archive can be read before it pulls the image or removes the old container. If backup creation or verification fails, the update stops and the script attempts to restart Seerr if it was running.

After the archive and maintenance record are saved, container recreation can still fail after the original container has been stopped or removed. The data volume and recovery files remain in place. Inspect Docker state and logs, then use the rollback command below to restore the previous image and inspected configuration. The script does not automatically roll back because an automatic replacement could compound a Docker or application failure.

The maintenance record stores whether Seerr was running before the update. If it was running, the replacement is started and checked for the expected image, volume, and HTTP response. If it was stopped, the replacement is created but left unstarted; the script verifies its image and volume and skips the HTTP check. Rollback restores that same running or stopped state.

Never use `-Apply` just to preview; run the dry run first.

## Backups and maintenance records

By default, archives and records are written to `%USERPROFILE%\SeerrBackup` (PowerShell resolves this from `$env:USERPROFILE`). A successful update creates matching files named:

- `seerr-data-yyyyMMdd-HHmmss-fff.tar.gz`
- `seerr-maintenance-yyyyMMdd-HHmmss-fff.json`

The `fff` part is the millisecond component of the timestamp. Existing files are not overwritten; a name collision stops the operation. The maintenance record stores the previous image ID and inspected container configuration, including environment settings that may contain secrets. Keep the backup directory private and do not commit its contents. The existing `seerr-data-backup.tar.gz` file is left untouched.

## Verify the update

Run each check separately in PowerShell:

```powershell
docker context show
```

```powershell
docker inspect seerr --format 'status={{.State.Status}} image={{.Image}}'
```

```powershell
docker inspect seerr --format '{{json .Mounts}}'
```

```powershell
Invoke-WebRequest -Uri http://localhost:5055 -TimeoutSec 10
```

For an update where Seerr was running before, confirm the status is `running`, the image ID matches the script summary, and `seerr-data` targets `/app/config` with read/write access. If Seerr was stopped before the update, the replacement remains unstarted; confirm its image and volume instead. The current deployment has no Docker health check configured. For a running replacement, the script uses container state and an HTTP response; it follows redirects and accepts final status codes from 200 through 399. A 4xx or 5xx response does not pass the check.

## Roll back

The script retains the previous image and reads the newest `seerr-maintenance-*.json` record from the backup directory. Before changing a container, rollback validates the record, confirms that the previous image ID exists locally, and verifies that the saved configuration uses the expected read/write volume mount.

After a failed update, run:

```powershell
pwsh -NoProfile -File .\Update-Seerr.ps1 -Rollback -ApplyRollback
```

When `seerr` exists, rollback first creates a stopped staging container from the saved configuration. Only after staging succeeds does it stop and remove the existing `seerr` container, rename the staged container to `seerr`, and start it. If staging fails, the existing container remains in place. If no `seerr` container exists, rollback creates the replacement directly.

Rollback restores the running/stopped state saved in the maintenance record. It verifies the restored image ID and named-volume mount in both cases; it checks HTTP readiness only when the previous Seerr container was running. A failure after the old container is removed may leave the replacement under its staging name or renamed to `seerr`; the error identifies which name to inspect:

```powershell
docker ps -a --filter "name=seerr" --no-trunc
```

If the replacement is still under a `seerr-rollback-...` staging name and no `seerr` container exists, rename the exact staging container shown by Docker and start it:

```powershell
docker rename <staging-container-name> seerr
docker start seerr
```

If the staging container has already been renamed to `seerr`, do not rename it again. Inspect its state and logs, then retry rollback to restore and verify the saved image and configuration. If the previous image is missing locally, use `PreviousImageId` from the maintenance record to retrieve that exact image before retrying.

## Inspect or restore an archive

List archive contents without extracting them:

```powershell
tar.exe -tzf "$env:USERPROFILE\SeerrBackup\seerr-data-yyyyMMdd-HHmmss-fff.tar.gz"
```

Replace the timestamp with the archive created by the update. To restore manually, stop Seerr and first preserve the current configuration. Extract the archive contents back into the existing `seerr-data` volume. Never remove the volume as a rollback step.
