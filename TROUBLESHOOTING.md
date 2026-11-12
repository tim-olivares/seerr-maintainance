# Troubleshooting and recovery

This guide covers the failure cases handled by `Update-Seerr.ps1` and the checks to make before retrying. Commands assume PowerShell 7 in the repository directory.

## The dry run stops before showing a plan

The script checks Docker connectivity and validates the current `seerr` container before it prints a plan. Check the active Docker context and server first:

```powershell
docker context show
docker info
docker ps -a --filter "name=^/seerr$"
docker inspect seerr --format '{{json .Mounts}}'
```

The container must use the `seerr-data` named volume read/write at `/app/config`. If it does not, stop and confirm the deployment layout before using this maintenance script.

## Backup creation or verification fails

The update stops before pulling an image or replacing the container. If Seerr was running, the script attempts to start it again. Confirm its state, then check free disk space and that Windows `tar.exe` is available:

```powershell
docker inspect seerr --format '{{.State.Status}}'
Get-PSDrive -Name C
Test-Path "$env:WINDIR\System32\tar.exe"
```

Do not remove the named volume to clear space. Backups are stored outside Docker in the configured backup directory. Preserve any archive that was successfully created before retrying.

## Update does not become responsive

The script waits up to `HealthTimeoutSeconds` for a running container and an HTTP response from `http://localhost:5055`. Inspect recent logs and container state:

```powershell
docker ps -a --filter "name=^/seerr$"
docker logs --tail 100 seerr
Invoke-WebRequest -Uri http://localhost:5055 -TimeoutSec 10
```

The deployment does not define a Docker health check, so the script uses container state and HTTP response checks. The response check accepts HTTP status codes from 200 through 499; investigate the application logs if the endpoint responds with an error status.

## Rollback cannot find its record or image

Rollback selects the newest `seerr-maintenance-*.json` file in the backup directory and requires the recorded previous image to exist locally. Review the record and local images:

```powershell
Get-ChildItem "$env:USERPROFILE\SeerrBackup\seerr-maintenance-*.json" | Sort-Object LastWriteTime -Descending
docker image ls --no-trunc
```

If the previous image is absent, retrieve the exact image ID recorded as `PreviousImageId` before retrying. Rollback validates the record, image, and saved volume mount before changing a container.

## Rollback leaves a staging container

When a `seerr` container already exists, rollback creates a stopped staging container before removing the existing one. If staging fails, the existing container remains in place. If recovery fails after the existing container was removed, inspect the named staging container:

```powershell
docker ps -a --filter "name=seerr-rollback-" --no-trunc
```

If the staging container exists and `seerr` does not, use the exact staging name shown by Docker:

```powershell
docker rename <staging-container-name> seerr
docker start seerr
```

Then rerun the rollback command to verify the saved image, volume mount, and HTTP endpoint:

```powershell
pwsh -NoProfile -File .\Update-Seerr.ps1 -Rollback -ApplyRollback
```

## Preserve the data volume

The named `seerr-data` volume contains the application configuration and database. The script does not remove, recreate, or prune it. Do not use `docker volume rm`, `docker volume prune`, or `docker system prune` as a troubleshooting step. Before manually restoring an archive, stop Seerr and preserve a copy of the current configuration.
