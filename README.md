# Gotenberg POC / Demo — CM Auto-Generate PDF

Supporting POC for research ticket **INC000011288638**
(research doc: `C:\10.4\docs\research-cm-auto-generate-pdf.md`).

Validates **Approach A** — a headless-Chromium rendering engine — using **Gotenberg** (MIT,
free for government use).

---

## 1. Answering the two setup questions

### "Can we run this as a side microservice on a Linux VM?"

**Yes — that is Gotenberg's intended deployment model.** It is a **stateless HTTP API**: no
database, no session state, no persistence. Each request is independent, so it scales horizontally
and restarts cleanly.

One constraint to know up front: **Gotenberg is distributed only as a container image.** There is
no standalone binary, MSI, or apt package. So "a Linux VM running Gotenberg" means Docker/Podman on
that VM — or a managed container service that runs the image for you.

| Host option | Fit for SOM | Notes |
|---|---|---|
| **Azure App Service for Containers (Linux)** | ✅ **Strong** | Mirrors the existing Playwright UI-test Web App pattern. Managed TLS, VNet integration, no VM patching. |
| **Azure Container Instances (ACI)** | ✅ Good | Fastest to stand up; good for the dev/POC tier. |
| **Azure Container Apps** | ✅ Good | Adds scale-to-zero and revisions; more moving parts. |
| **Linux VM + Docker** | ⚠️ Works | Full control, but you own OS patching, Docker upgrades, and hardening. |
| **The Windows-container Sitecore compose stack** | ❌ **Not possible** | Gotenberg is a Linux image; that stack is Windows containers. See §2. |

**Key consequence:** because Gotenberg lives outside the Sitecore compose stack, the
Windows/Linux container conflict is only a **local-dev inconvenience**, not an architectural
problem. Once a dev-tier instance exists, local developers point CM at it and never run Gotenberg
on their own machine.

### "We only use Docker for local environments"

That is compatible — just note the distinction:
- **Gotenberg always runs as a container** (its only distribution format).
- But **you don't have to manage Docker** if you use App Service for Containers / ACI / Container
  Apps. Azure pulls and runs the image; you supply the image reference and configuration.

---

## 2. Why it can't go in the Sitecore compose stack

Verified on this machine:

| Check | Value |
|---|---|
| Docker server platform | **windows** (hyperv isolation), v28.3.2 |
| Docker Desktop | Installed |
| WSL distributions | **none installed** |
| Sitecore stack | Running & healthy — cm, cd, id, solr, mssql, redis, sps |

Gotenberg's image is Debian-based (Chromium + LibreOffice). Linux containers need a Linux kernel;
Windows containers need the Windows kernel. Docker serves one platform at a time, so the two cannot
coexist in one compose stack.

### Option 0 — Hosted demo instance (fastest signal, ~60 seconds, no install)

Gotenberg runs a public demo at `https://demo.gotenberg.dev`. This is the quickest way to confirm
the API shape and basic output quality:

```powershell
# URL -> PDF
curl.exe --request POST https://demo.gotenberg.dev/forms/chromium/convert/url `
  --form url=https://example.com `
  --form emulatedMediaType=print --form printBackground=true `
  --form generateTaggedPdf=true -o demo-url.pdf
```

**Use it only with public, non-sensitive pages.** Hard limits and cautions:

| Limit | Impact |
|---|---|
| **Third-party hosted service** | ❌ **Never send real guidance-page or draft CM content.** Same architectural objection the research raises against PDFShift/SnapRender — content leaving the environment violates **AC11/AC12**. |
| Cannot reach `cm.michigan.local` | ❌ Authenticated draft preview rendering (§6.3 — the highest-risk unknown) is impossible. |
| 512 MB RAM / 0.5 CPU | ❌ No realistic resource or batch sizing. |
| 2 requests/sec per IP, 5 MB body | ❌ Cannot exercise the 20–30 page batch (AC6). |

**Verdict:** fine for a first look at fidelity and the print-CSS expansion behaviour; useless
for the two questions that actually carry risk (CM draft auth and batch scale). Self-host for those.

### Local options to actually run the POC

**Option 1 — Dev-tier instance in Azure (recommended, matches the target architecture).**
Deploy the image to ACI or App Service for Containers, then point this harness at it:
```powershell
.\Test-Gotenberg.ps1 -GotenbergUrl "https://gotenberg-dev.internal.example" -SkipContainerStart
```
No local disruption, and it validates the real deployment shape.

**Option 2 — WSL2 + Docker in WSL (the only local way to test CM URLs).** ✅

WSL2 runs **independently of the Docker Desktop engine mode**, so Docker Desktop stays in
**Windows-container** mode and Sitecore + Traefik keep working normally. This is the only local
option that can render authenticated **CM preview URLs** (research §6.3 — the highest-risk unknown).

```powershell
# 1. Windows (admin) - keep Docker Desktop in WINDOWS container mode
wsl --install -d Ubuntu          # may require a reboot
```

```bash
# 2. Inside Ubuntu
sudo apt-get update && sudo apt-get install -y docker.io
sudo service docker start

# 3. Resolve the Windows host IP (WSL's default gateway in NAT mode)
WINHOST=$(ip route show default | awk '{print $3}'); echo "Windows host: $WINHOST"

# 4. Run Gotenberg, mapping cm.michigan.local to the Windows host and
#    tolerating Traefik's self-signed certificate (LOCAL TESTING ONLY)
sudo docker run -d --name gotenberg -p 3000:3000 \
  --add-host "cm.michigan.local:$WINHOST" \
  gotenberg/gotenberg:8.34.0 \
  gotenberg --chromium-ignore-certificate-errors

# 5. Smoke test from inside WSL
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/health
```

```powershell
# 6. Back on Windows - WSL2 forwards localhost, so the harness just works.
#    Put the CM URLs in sample\urls.txt first.
cd C:\GotenbergDemo
.\Test-Gotenberg.ps1 -SkipContainerStart
```

Expect to wrestle the self-signed certificate and **CM authentication** — a 404/401/redirect-to-login
in the resulting PDF *is* the finding for research §6.3, and it is exactly what needs solving
(preview session cookie vs SSC token vs service account).

**Option 3 — Switch Docker to Linux containers (tool validation only).**

Switching engines does **not** stop the Sitecore containers — Docker Desktop's prompt confirms they
keep running, you just can't *manage* them until you switch back. **No `.\down.ps1` needed.**

```powershell
& 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchLinuxEngine
cd C:\GotenbergDemo ; .\Test-Gotenberg.ps1
& 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchWindowsEngine   # regain CLI control
```

> ⚠️ **VERIFIED LIMITATION: CM becomes unreachable in Linux mode, so Option 3 cannot test CM URLs.**
>
> Traefik discovers its routes through the Docker named pipe:
> ```yaml
> --providers.docker.endpoint=npipe:////./pipe/docker_engine
> ```
> When Docker Desktop switches to Linux, that pipe is **re-pointed to the Linux daemon**. Traefik
> stays alive but now sees zero containers, so it drops every dynamic route. The symptom is a
> **404 from `https://cm.michigan.local/sitecore`** (Traefik answering, but with no matching route)
> rather than a connection error. CM/CD/SQL are still running — just unroutable by hostname.
>
> **After switching back to Windows mode**, routes should return once the pipe is restored. If they
> don't, restart Traefik:
> ```powershell
> cd C:\10.4\docker ; docker compose restart traefik
> ```
> **To test CM + Gotenberg together, use Option 2 (WSL2)** — it is independent of the Docker Desktop
> engine mode, so Sitecore and Traefik keep working normally.

---

## 3. SECURITY — read before deploying anywhere reachable

Gotenberg has a significant recent CVE history:

| CVE | Issue | Fixed in |
|---|---|---|
| **CVE-2026-40281** | **Unauthenticated RCE** via argument injection — public PoC exploit exists | after 8.30.1 |
| CVE-2026-42595 | SSRF — Chromium follows redirects to internal targets without re-validating | later 8.x |
| CVE-2026-42596 | Unauthenticated SSRF — deny-list bypass (e.g. IPv6-mapped loopback) | later 8.x |
| CVE-2026-40280 / 27018 | Auth-bypass — case-sensitive deny-list regex bypassed by `HTTP://` | later 8.x |
| CVE-2026-42594 | Unauthenticated DoS — webhook goroutine panic | later 8.x |
| CVE-2026-44829 | Path traversal via crafted zip entry names | 8.33 |
| CVE-2026-55229 | SSRF in `/forms/libreoffice/convert` | 8.34 |

_CVE summaries paraphrased from advisory sources for licensing compliance._

**Mandatory controls for any non-throwaway deployment:**

1. **Pin an explicit patched version.** Do **not** use the floating `:8` tag. Check the
   [releases page](https://github.com/gotenberg/gotenberg/releases) for the current version at
   deploy time and pin it. Treat this as a recurring patch obligation.
2. **Never expose it publicly.** Private subnet / VNet-integrated only, with an NSG or access
   restriction permitting **only the CM host**. There must be no public ingress.
3. **Enable its built-in basic auth.** Gotenberg **does** ship authentication — it is just **off by
   default**. Use `--api-enable-basic-auth` with the `GOTENBERG_API_BASIC_AUTH_USERNAME` /
   `GOTENBERG_API_BASIC_AUTH_PASSWORD` environment variables (source them from Key Vault / pipeline
   secrets). Treat this as defence-in-depth on top of network isolation, not a replacement.
   _(Corrects an earlier assumption in this document that Gotenberg had no auth.)_
4. **Constrain what it may fetch** using `--chromium-allow-list` so it can only reach the CM
   preview host — the primary SSRF mitigation, directly supporting AC12. Also enable the
   **resolve-then-check** guards `--api-download-from-deny-private-ips` and
   `--webhook-deny-private-ips`; these inspect the *resolved IP* and so defeat the regex-bypass
   class of CVEs (mixed-case schemes, IPv6-mapped loopback, redirects) that plain deny-lists missed.
5. **Disable unused features.** The `downloadFrom` and `webhook` features are the documented SSRF
   vectors. _Verify exact flag names against the pinned version's docs — they have changed across
   releases._
6. **Choose the image variant deliberately** — see §3a. It is both a security-surface and a
   capability decision.

The vendor's own installation guidance says the same thing in plainer terms: do not expose Gotenberg
to the public internet; treat it like a database and keep it behind the firewall.

---

## 3a. Image variant decision (security surface vs PDF/UA capability)

Gotenberg ships three variants. All of them include **PDF Engines**, so **merge (AC8) is available
in every variant** — no need to validate that separately.

| Variant | Size | URL/HTML → PDF | Merge/split/watermark | **PDF/A & PDF/UA conversion** | Office docs |
|---|---|---|---|---|---|
| `gotenberg/gotenberg:8` | Full | ✅ | ✅ | ✅ | ✅ |
| `gotenberg/gotenberg:8-chromium` | ~30% smaller | ✅ | ✅ | **❌** | ❌ |
| `gotenberg/gotenberg:8-libreoffice` | ~40% smaller | ❌ | ✅ | ✅ | ✅ |

**The trade-off that matters for this ticket:**

- **`8-chromium`** covers everything the ACs strictly need — URL/HTML→PDF (AC2/AC3) and merge (AC8) —
  with a **smaller attack surface**. Dropping LibreOffice also removes the route implicated in
  **CVE-2026-55229** entirely. **But it cannot do PDF/A or PDF/UA conversion.**
- **Full `8`** adds **PDF/A & PDF/UA conversion**, which is directly relevant because accessibility is
  the business driver — at the cost of carrying LibreOffice.

**Important distinction:** Chromium's `generateTaggedPdf` option produces a **tagged** PDF and works
in `8-chromium`. What the slim variant loses is PDF/A and **PDF/UA conversion** (a separate
post-processing step that needs LibreOffice). Tagged ≠ PDF/UA-conformant — see research §2.6.

**POC recommendation:** use the **full image** so nothing is missing while testing, and measure
whether PDF/UA conversion actually improves the output enough to justify keeping LibreOffice in
production. Decide the production variant from that evidence.

### Other deployment notes from the vendor docs

- Runs as **non-root** (`gotenberg`, UID/GID 1001); arbitrary UIDs supported since 8.21.0.
- Kubernetes `securityContext`: `readOnlyRootFilesystem: false`, `allowPrivilegeEscalation: false`,
  `privileged: false`, `runAsUser: 1001`.
- Resource floor: **≥ 512Mi memory and 0.2 CPU**; ≥ 1Gi recommended for comfortable operation. Our
  compose sets a 2G ceiling — tune against real guidance pages and the AC6 batch size.
- In a shared Compose network, other services reach it at **`gotenberg:3000`**.
- Preconfigured variants exist for **Cloud Run** and **AWS Lambda (beta)**, which is a good signal
  that Azure App Service for Containers / Container Apps will host it without friction.

This CVE history is a legitimate input to the Approach A vs B decision and belongs in the security
review. It does not disqualify Gotenberg — it is actively maintained and these were patched — but it
does mean **network isolation plus a patch cadence are non-negotiable**.

---

## 4. What the harness does

The synthetic `print-test.html` page already confirmed the basics (JS executes, flexbox/grid
render, print CSS expands hidden content, merge works), so it and its tests were removed.
`Test-Gotenberg.ps1` now renders real pages: every URL in `sample/urls.txt` is converted to a PDF
through Gotenberg's Chromium URL route (print media emulation, backgrounds, tagged PDF, 2 s wait).

Edit `sample/urls.txt` (one URL per line; blank lines and `#` comments are ignored), then run:

```powershell
# Local container (requires Linux-container mode)
.\Test-Gotenberg.ps1

# Against an existing dev instance, no local container
.\Test-Gotenberg.ps1 -GotenbergUrl "http://gotenberg-dev:3000" -SkipContainerStart

# Use a different list, and leave the container running
.\Test-Gotenberg.ps1 -UrlListPath sample\other-urls.txt -KeepRunning
```

Each PDF lands in `output/pages/` (gitignored), named after the last path segment of its URL:
`.../composites/tabs` becomes `tabs.pdf`. A URL with no path uses the host name, and repeated
names get `-2`, `-3`. The script exits with code 1 if any URL fails.

Current test pages (`cmstest.michigan.gov/agencysite/components/...`): `accordions`, `tabs`,
`promocardgroup`, `featureitem`, `timeline`.

Not covered yet: pages that need a login. Gotenberg cannot authenticate by itself; cookies or
headers must be passed per request, and the script does not do that yet (research §6.3).

---

## 5. How to judge the results

1. Open each PDF in `output/pages/` and compare it with the page in a browser.
2. Check that **collapsed content is present**. `accordions.pdf` and `tabs.pdf` should show every
   section and tab. If they are collapsed, the site needs a print stylesheet (or injected
   CSS/JS) that expands them, which is the research §6.5 print-view idea.
3. Check layout and styling: cards, grids, timeline, images and fonts should match the screen, and
   navigation chrome should not dominate the output.
4. If a PDF looks unstyled or is missing images, Chromium may have been blocked from loading
   assets (allow-list) or could not reach a CDN.
5. Optionally validate tagging with [veraPDF](https://verapdf.org/) and **expect imperfect PDF/UA**
   (research §2.6). Do not promise a compliant PDF in either approach.

---

## 6. Files

| File | Purpose |
|---|---|
| `README.md` | This document |
| `Commands.md` | Copy-paste commands to run the project |
| `Test-Gotenberg.ps1` | POC harness: renders each URL in the list to a PDF |
| `docker-compose.yml` | Hardened, version-pinned Gotenberg service for a Linux VM / dev tier |
| `sample/urls.txt` | URLs to render, one per line |
| `output/pages/` | Generated PDFs, named by last URL path segment (gitignored) |

Nothing here modifies the Sitecore solution, `docker-compose.yml` in `C:\10.4`, or any Sitecore
configuration.
