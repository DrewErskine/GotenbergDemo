# Commands to Run the Gotenberg POC

All commands run in PowerShell from `C:\GotenbergDemo`.

```powershell
cd C:\GotenbergDemo
```

## Prerequisites

- Docker Desktop installed and running
- Docker in **Linux-container mode** (Gotenberg is a Linux image), unless you target an existing instance with `-SkipContainerStart`
- `curl.exe` (included with Windows 10+)

If PowerShell blocks the script:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

## 1. Add the pages to test

Edit `sample\urls.txt`: one URL per line. Blank lines and lines starting with `#` are ignored.

## 2. Run

Starts `gotenberg/gotenberg:8.34.0`, renders every URL in `sample\urls.txt`, then removes the container.

```powershell
.\Test-Gotenberg.ps1
```

Each PDF is written to `output\pages\<last-path-segment>.pdf`:

- `https://www.michigan.gov/mdhhs/assistance-programs/` becomes `assistance-programs.pdf`
- A URL with no path uses the host name
- Repeated names get `-2`, `-3`
- The script exits with code 1 if any URL fails

Use a different list or an existing instance:

```powershell
.\Test-Gotenberg.ps1 -UrlListPath sample\other-urls.txt
.\Test-Gotenberg.ps1 -GotenbergUrl "http://<dev-host>:3000" -SkipContainerStart
.\Test-Gotenberg.ps1 -KeepRunning
```

## 3. Switch Docker engines (the Sitecore stack uses Windows mode)

Sitecore containers keep running during the switch. You just can't manage them until you switch back.

```powershell
# Switch to Linux containers
& 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchLinuxEngine

# Run the harness
.\Test-Gotenberg.ps1

# Switch back to Windows containers
& 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchWindowsEngine
```

Note: while in Linux mode, Traefik loses its routes and `https://cm.michigan.local` returns 404. If routes don't return after switching back:

```powershell
cd C:\10.4\docker ; docker compose restart traefik
```

## 4. Script parameters

| Parameter | Purpose | Default |
|---|---|---|
| `-UrlListPath` | Text file of URLs to render | `sample\urls.txt` |
| `-GotenbergUrl` | Base URL of the Gotenberg instance | `http://localhost:3000` |
| `-SkipContainerStart` | Don't start or stop a local container | off |
| `-ImageTag` | Pinned Gotenberg image | `gotenberg/gotenberg:8.34.0` |
| `-KeepRunning` | Leave the container running afterward | off |

## 5. Run with Docker Compose (hardened service)

The password is required. The compose file enables basic auth, and the script sends no credentials, so the script gets a 401 against this instance. The compose allow-list also only permits the CM hosts, so add your michigan.gov test hosts to it first.

```powershell
$env:GOTENBERG_PASSWORD = "<your-password>"
docker compose up -d
docker compose ps
docker compose logs gotenberg --tail 40
docker compose down
```

Health check:

```powershell
curl.exe http://localhost:3000/health
```

## 6. Manual API call

Against a running instance (use `curl.exe`, not the `curl` alias).

```powershell
curl.exe --request POST http://localhost:3000/forms/chromium/convert/url `
  --form url=https://www.michigan.gov/mdhhs `
  --form emulatedMediaType=print --form printBackground=true `
  --form generateTaggedPdf=true --form waitDelay=2s -o output\manual-url.pdf
```

## 7. Cleanup

```powershell
docker rm -f gotenberg-poc    # container started by Test-Gotenberg.ps1
docker rm -f gotenberg        # container started by docker-compose / WSL
```
