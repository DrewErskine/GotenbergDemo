# Improvements to Look Into


### 1. Keep the container always running on the server

Today `Test-Gotenberg.ps1` starts a throwaway container (`gotenberg-poc`) and removes it when the run finishes unless `-KeepRunning` is passed. That suits a local test. On a server, Gotenberg should be a long-lived service that the script (or the CM) only calls.

Things to look into:

- Use `-SkipContainerStart` against the server instance. Consider making that the default for server runs, or splitting the script into "manage the container" and "render URLs" parts.
- Decide how to monitor it (health endpoint, alerts when it is down or restarting).
- Plan the patch process: pinned image tag, who bumps it, and how often (see Security).

### 2. Lazy-loaded images missing from the PDF

Only the first image showed up in the generated PDFs. Images with `loading="lazy"` load when they scroll into view, and headless Chromium never scrolls, so they print blank. Gotenberg's maintainer describes this in [discussion #1580](https://github.com/gotenberg/gotenberg/discussions/1580).

`Test-Gotenberg.ps1` now sends a `waitForExpression` that removes the `loading` attribute from every image and waits until all images report `complete`. It is passed with `--form-string` because the expression contains a `;`.

- Cleaner fix: have the site stop using `loading="lazy"` for printed output (the maintainer's preferred option). That needs a change in the site markup.


