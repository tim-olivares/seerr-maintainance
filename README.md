# Seerr Maintenance & Update Tool

PowerShell 7 maintenance utility for updating the existing Seerr Docker container while preserving its named configuration volume. See [Troubleshooting and recovery](TROUBLESHOOTING.md) for failure handling.

`Update-Seerr.ps1` updates the existing Seerr container using its inspected runtime configuration. It checks Docker, verifies the `seerr-data` named volume is mounted read/write at `/app/config`, checks free disk space, makes and integrity-checks a timestamped configuration/database archive, pulls the requested image, then recreates only the `seerr` container. The named volume is never removed or recreated. It retains the previous image and writes a maintenance record containing its image ID and inspected configuration for rollback.

The script uses the current container inspection as the source for environment, mounts, ports, restart policy, network mode, labels, command, and other common runtime settings. Review the dry-run summary before applying. The script has no commands for volume removal/pruning or system pruning and does not address other containers.

## Dry run

Open PowerShell 7 in this project directory and run:

```powershell
pwsh -NoProfile -File .\Update-Seerr.ps1
```

This is the default. It inspects Docker and prints the planned target image, current image ID, volume, backup path, free space, and HTTP check. It does not stop or modify the container, pull an image, or write a backup.

## Execute an update

```powershell
pwsh -NoProfile -File .\Update-Seerr.ps1 -Apply
```

The update stops Seerr to get a consistent copy of its SQLite database and files, copies `/app/config` from that stopped container, creates a unique `.tar.gz`, and verifies the archive before proceeding. If backup creation or verification fails, the script restarts the old container (if it had been running) and stops. It then pulls the image, records the prior inspected configuration and image ID, and recreates the container. The script waits up to 180 seconds for it to be running and for `http://localhost:5055` to respond.

Never use `-Apply` just to preview. Run the dry run first and review its output.

## Backups and records

By default, archives and maintenance records are stored in:

```text
C:\Users\LeftTi-2.0\SeerrBackup
```

Each update creates `seerr-data-yyyyMMdd-HHmmss-fff.tar.gz` and a matching `seerr-maintenance-yyyyMMdd-HHmmss-fff.json`. Existing archives are not overwritten; timestamp collisions fail safely. The maintenance record stores the previous image ID and configuration. The existing backup at `C:\Users\LeftTi-2.0\SeerrBackup\seerr-data-backup.tar.gz` remains untouched.

## Verify the update

```powershell
docker context show
docker inspect seerr --format 'status={{.State.Status}} image={{.Image}}'
docker inspect seerr --format '{{json .Mounts}}'
Invoke-WebRequest -Uri http://localhost:5055 -TimeoutSec 10
```

The mount output should show `seerr-data` targeting `/app/config`; status should be `running`; the image ID should match the script summary. The current deployment has no Docker health check configured, so the script checks container state and the HTTP endpoint instead.

## Roll back

The previous image is retained; this tool never removes it. Rollback loads and validates the newest maintenance record and verifies that the recorded previous image exists locally before inspecting the current Seerr container. It also verifies the saved configuration has the expected `seerr-data` read/write mount at `/app/config` and that the named volume exists. This means rollback can recover even if an earlier failed update removed `seerr` and failed to create its replacement.

After a failed update, run the following from this directory:

```powershell
pwsh -NoProfile -File .\Update-Seerr.ps1 -Rollback -ApplyRollback
```

If a Seerr container exists, rollback creates a stopped staging container with the saved configuration first. Only after that succeeds does it stop and remove the existing `seerr` container, rename the staged container to `seerr`, and start it. If no current `seerr` container exists, rollback creates it directly. The script verifies that the recreated container is running with the saved image ID and volume mount, then checks `http://localhost:5055`. It never removes, recreates, or prunes `seerr-data`, and it never acts on other containers.

If staging fails, the existing Seerr container is left in place. If an error occurs after the old container has been removed, the error reports the staging container name when available. Inspect it with:

```powershell
docker ps -a --filter "name=seerr-rollback-" --no-trunc
```

If the named staging container exists and `seerr` does not, recover it with the exact name printed in the script error:

```powershell
docker rename <staging-container-name> seerr
docker start seerr
```

Then rerun the rollback command to verify the image, volume, and HTTP endpoint. If the previous image is no longer available locally, rollback stops before changing any container; use the recorded `PreviousImageId` and inspect JSON in the maintenance record to retrieve that exact image before retrying.

The configuration archive can be inspected without extracting it using:

```powershell
tar.exe -tzf C:\Users\LeftTi-2.0\SeerrBackup\seerr-data-yyyyMMdd-HHmmss.tar.gz
```

Replace the timestamp with the archive created by the update. Restore only when Seerr is stopped and after preserving the current config; extract the archive contents back into the existing `seerr-data` volume. Never remove the volume as a rollback step.
