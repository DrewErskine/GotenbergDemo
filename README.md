# Gotenberg POC — CM Auto-Generate PDF

Supporting POC for research ticket **INC000011288638**
(research doc: `C:\10.4\docs\research-cm-auto-generate-pdf.md`).

Validates **Approach A**, a headless-Chromium rendering engine, using **Gotenberg** (MIT).
Run commands are in [`Commands.md`](Commands.md). Open items are in [`Improvements.md`](Improvements.md).

---

## 1. Deployment

Gotenberg is a **stateless HTTP API** distributed **only as a Linux container image** (no binary,
MSI or apt package). Each request is independent, so it scales horizontally and restarts cleanly.

| Host option | Fit | Notes |
|---|---|---|
| **Azure App Service for Containers (Linux)** | ✅ Strong | Mirrors the existing Playwright UI-test Web App pattern. Managed TLS, VNet integration, no VM patching. |
| **Azure Container Instances** | ✅ Good | Fastest to stand up; good for the dev tier. |
| **Azure Container Apps** | ✅ Good | Scale-to-zero and revisions; more moving parts. |
| **Linux VM + Docker** | ⚠️ Works | You own OS patching, Docker upgrades and hardening. |
| **Windows-container Sitecore compose stack** | ❌ Not possible | Gotenberg is a Linux image; that stack is Windows containers. |

Because Gotenberg runs outside the Sitecore stack, the Windows/Linux conflict is only a local-dev
inconvenience. Once a dev-tier instance exists, developers point CM at it and never run Gotenberg
locally. With a managed service, you don't manage Docker yourself; Azure runs the image.

---

## 2. Running it locally

Docker Desktop here is in Windows-container mode (Sitecore + Traefik), and Gotenberg needs Linux
containers. Options:

| Option | Use for | Notes |
|---|---|---|
| **1. Dev-tier instance in Azure** (recommended) | Everything | Matches the target architecture. Run the harness with `-GotenbergUrl ... -SkipContainerStart`. |
| **2. WSL2 + Docker in WSL** | Rendering CM URLs | Independent of the Docker Desktop mode, so Sitecore keeps working. |
| **3. Switch Docker to Linux containers** | Public pages only | Sitecore keeps running, but CM becomes unreachable (see below). |
| **0. Hosted demo** (`demo.gotenberg.dev`) | A first look at output quality | Public third-party service. **Never send real or draft CM content** (violates AC11/AC12). Limits: 512 MB RAM, 2 requests/sec, 5 MB body. |

**Option 3 limitation:** Traefik finds its routes through the Docker named pipe
(`npipe:////./pipe/docker_engine`). Switching to Linux re-points that pipe, so Traefik sees no
containers and `https://cm.michigan.local` answers 404. After switching back, restart Traefik if
routes don't return: `cd C:\10.4\docker ; docker compose restart traefik`.

**Option 2 setup** (the only local way to test CM URLs):

```powershell
wsl --install -d Ubuntu          # admin; may require a reboot
```

```bash
# Inside Ubuntu
sudo apt-get update && sudo apt-get install -y docker.io
sudo service docker start

# Windows host IP (WSL's default gateway in NAT mode)
WINHOST=$(ip route show default | awk '{print $3}')

# Map cm.michigan.local to the Windows host; accept Traefik's self-signed cert (LOCAL ONLY)
sudo docker run -d --name gotenberg -p 3000:3000 \
  --add-host "cm.michigan.local:$WINHOST" \
  gotenberg/gotenberg:9.6.0 \
  gotenberg --chromium-ignore-certificate-errors
```

Then, from Windows, with the CM URLs in `sample\urls.txt` (WSL2 forwards `localhost`):

```powershell
.\Test-Gotenberg.ps1 -SkipContainerStart
```

Expect to deal with the self-signed certificate and **CM authentication**. A 404, 401 or login
redirect in the PDF *is* the finding for research §6.3 (preview session cookie vs SSC token vs
service account).

---

## 3. Security — read before deploying anywhere reachable

Gotenberg has a significant recent CVE history. These were fixed in the 8.x line, which ended at
8.40.0. This project pins **9.6.0**; check the releases page for 9.x advisories at deploy time.

| CVE | Issue | Fixed in |
|---|---|---|
| **CVE-2026-40281** | **Unauthenticated RCE** via argument injection; public PoC exists | after 8.30.1 |
| CVE-2026-42595 | SSRF: Chromium follows redirects to internal targets without re-validating | later 8.x |
| CVE-2026-42596 | Unauthenticated SSRF: deny-list bypass (e.g. IPv6-mapped loopback) | later 8.x |
| CVE-2026-40280 / 27018 | Auth bypass: case-sensitive deny-list regex bypassed by `HTTP://` | later 8.x |
| CVE-2026-42594 | Unauthenticated DoS: webhook goroutine panic | later 8.x |
| CVE-2026-44829 | Path traversal via crafted zip entry names | 8.33 |
| CVE-2026-55229 | SSRF in `/forms/libreoffice/convert` | 8.34 |

_CVE summaries paraphrased from advisory sources for licensing compliance._

**Controls for any non-throwaway deployment** (all set in `docker-compose.yml`):

1. **Pin an explicit patched version.** Never use the floating `:9` tag. Check the
   [releases page](https://github.com/gotenberg/gotenberg/releases) at deploy time and treat
   patching as a recurring obligation.
2. **Never expose it publicly.** Private subnet or VNet only, with access restricted to the CM host.
   The vendor says the same: keep it behind the firewall, like a database.
3. **Enable basic auth.** It is off by default. Use `--api-enable-basic-auth` with
   `GOTENBERG_API_BASIC_AUTH_USERNAME` / `GOTENBERG_API_BASIC_AUTH_PASSWORD` from Key Vault or
   pipeline secrets. This is defence in depth, not a replacement for network isolation.
4. **Constrain what it may fetch** with `--chromium-allow-list` (the primary SSRF mitigation,
   supporting AC12). Also enable the resolve-then-check guards `--api-download-from-deny-private-ips`
   and `--webhook-deny-private-ips`, which inspect the resolved IP and so defeat the regex-bypass
   class of CVEs.
5. **Disable unused features** (`--api-disable-download-from`). Flag names change between releases,
   so verify them against the pinned version with `gotenberg --help`. All flags in the compose file
   were verified against 9.6.0.
6. **Choose the image variant deliberately** (below).

The CVE history belongs in the Approach A vs B security review. It does not disqualify Gotenberg,
since it is actively maintained and these were patched, but **network isolation and a patch cadence
are non-negotiable**.

### Image variant

In Gotenberg 9, every variant processes PDFs with litho (merge, split, stamp, PDF/A, PDF/UA). The
variants differ only in the conversion engines they carry
([docs](https://gotenberg.dev/docs/getting-started/installation)). A route whose engine the image
lacks answers 404.

| Variant | Converts |
|---|---|
| `gotenberg/gotenberg:9` | Web pages and office documents |
| `gotenberg/gotenberg:9-chromium` | Web pages, screenshots |
| `gotenberg/gotenberg:9-libreoffice` | Office documents |

`9-chromium` covers everything this ticket needs (URL/HTML to PDF, merge) with a smaller attack
surface, and it drops the LibreOffice routes implicated in CVE-2026-55229. The harness currently
runs the full image. `9-chromium` is the likely production choice, but **that is untested**: confirm
with a run before committing.

`nativeTaggedPdf` writes a **tagged** PDF in every Chromium variant. Tagged is not PDF/UA-conformant.
Conformance needs a `remediate` stage (see `Improvements.md` item 5) and validation (research §2.6).

**Resources:** vendor floor is 512Mi memory and 0.2 CPU; 1Gi or more is recommended. The compose
file sets a 2G / 2 CPU limit. Tune it against real pages and the AC6 batch size (20-30 pages).

---

## 4. Licensing

- **Gotenberg** is MIT licensed, in 8.x and 9.x ([LICENSE](https://github.com/gotenberg/gotenberg/blob/main/LICENSE)).
- **Gotenberg 9 added litho**, a PDF engine that replaces pdfcpu, QPDF, pdftk and ExifTool. litho's
  own repository is licensed **AGPL-3.0**. Per the [litho README](https://github.com/gotenberg/litho),
  Gotenberg embeds litho and ships it under the MIT license, as its copyright owner allows, and
  contributors sign a CLA granting that right. The AGPL applies to *other* uses of litho, such as
  importing it into your own program. This project runs the Gotenberg image and calls its HTTP API,
  so it is not that case.
- **Not verified:** this rests on the vendor's statement. It is not legal advice, and the licenses of
  other software in the image (Chromium, LibreOffice) were not audited. Have licensing review confirm
  the v9 position before production use.

---

## 5. What the harness does

`Test-Gotenberg.ps1` converts every URL in `sample/urls.txt` (one per line; blank lines and `#`
comments ignored) to a PDF through Gotenberg's Chromium URL route. Run commands and parameters are in
`Commands.md`.

- **Settings:** print media emulation, backgrounds, tagged PDF, a custom page size, and a wait that
  loads lazy images (`Improvements.md` items 2 and 3).
- **Output:** `output/pages/` (gitignored), named after the last path segment of the URL
  (`.../composites/tabs` becomes `tabs.pdf`). A URL with no path uses the host name, and repeated
  names get `-2`, `-3`. The script exits with code 1 if any URL fails.
- **Current test pages** (`cmstest.michigan.gov/agencysite/components/...`): `accordions`, `tabs`,
  `promocardgroup`, `featureitem`, `timeline`.
- **Not covered yet:** pages that need a login. Gotenberg cannot authenticate by itself; cookies or
  headers must be passed per request, and the script doesn't do that yet (research §6.3).

An earlier synthetic page (`print-test.html`) confirmed the basics (JS runs, flexbox/grid render,
print CSS expands hidden content, merge works) and was removed.

### How to judge the results

1. Open each PDF in `output/pages/` and compare it with the page in a browser.
2. Check that **collapsed content is present**. `accordions.pdf` and `tabs.pdf` should show every
   section and tab. If not, the page needs print CSS or injected CSS/JS to expand them (research §6.5).
3. Check layout: cards, grids, timeline, images and fonts should match the screen.
4. If a PDF is unstyled or missing images, Chromium may have been blocked by the allow-list or could
   not reach a CDN.
5. Optionally validate tagging with [veraPDF](https://verapdf.org/). **Expect imperfect PDF/UA**
   (research §2.6) and don't promise a compliant PDF in either approach.

---

## 6. Files

| File | Purpose |
|---|---|
| `README.md` | This document |
| `Commands.md` | Commands to run the project |
| `Improvements.md` | Open items to look into |
| `Test-Gotenberg.ps1` | POC harness: renders each URL in the list to a PDF |
| `docker-compose.yml` | Hardened, version-pinned Gotenberg service for a Linux VM or dev tier |
| `sample/urls.txt` | URLs to render |
| `output/pages/` | Generated PDFs (gitignored) |

Nothing here modifies the Sitecore solution, the `docker-compose.yml` in `C:\10.4`, or any Sitecore
configuration.
