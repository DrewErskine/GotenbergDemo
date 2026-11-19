# PDF Generation Options for CM Pages

Ticket INC000011288638. This compares the three approaches discussed so far. It records what was tested, what was only read in documentation, and what is still unknown.

## Constraint

All environments (production and lower) run on **Windows App Service, not containers**. Nothing runs on Linux. Anything that needs a Linux host means standing up a new service.

The README refers to these acceptance criteria: AC2/AC3 (render a page), AC6 (a 20 to 30 page batch), AC8 (merge in order) and AC11/AC12 (content stays inside the environment). The research document was not found at `C:\10.4\docs`, so the exact wording is unconfirmed.

## At a glance

| | A. Gotenberg | B. JSON device + library inside Sitecore | C. Button in the visitor's browser |
|---|---|---|---|
| What makes the PDF | Headless Chromium in a Linux container | A commercial .NET library with an embedded browser, running in CM | The visitor's own browser print engine |
| New infrastructure | A Linux service (not available today) | None, but a license | None |
| Status | Working demo in this repo | Nothing built | Working code from a coworker (`emi-generate-pdf-0.1.0`), tested via its CLI |
| Look | Closest to the live site | Whatever HTML and CSS you build | Plain document look, not the site's styling |
| Trigger | Script or API call | Server side (ribbon, batch) | A visitor clicks a button, then chooses "Save as PDF" |
| Works on any page today | Yes | Not built | eBooks only (generalizing is a later task) |

---

## A. Gotenberg

**What it is.** An open-source HTTP service shipped as a Linux container image. You POST a URL and get a PDF back. It wraps headless Chromium. Gotenberg is MIT licensed. Version 9 embeds a PDF engine called litho, which is AGPL-3.0 in its own repository, but Gotenberg ships it under MIT per the litho README. See README section 4.

**Where it stands.** `Test-Gotenberg.ps1` renders a list of URLs, pinned to Gotenberg 9.9.0.

**What the demo proved** (run against `cmstest.michigan.gov`):
- Real pages render with their layout, fonts and images.
- Lazy-loaded images need a fix (strip `loading="lazy"`, wait for images). Done.
- A wider custom page (1280 x 1810 px) stops the site switching to its mobile layout. Done.
- `print` media makes the site's CSS expand accordions but also hides the hero. `screen` media shows the hero but leaves accordions collapsed. This is a trade-off, not solved (`Improvements.md` item 4).
- Merging works. The five ebook pages became one 10-page tagged PDF with five bookmarks in list order.

**Open items:** hiding the alert and nav (item 6), PDF/UA repair (item 5), and pages that need a login.

**Blocker.** It needs a Linux container host (README section 1 lists Azure Container Instances, Linux App Service and Container Apps). It must also be kept off the public internet, behind basic auth, and patched. The CVE history is in README section 3.

---

## B. JSON device + a library inside Sitecore

**Idea.** Sitecore already produces a JSON version of each page (the SXA JSON device). Code in CM turns that JSON into HTML and passes it to a library that bundles a browser engine, so everything stays inside Sitecore. A library can also render a URL directly, which would give the same look as Gotenberg without using the JSON.

### The hosting problem

Azure's own [sandbox page](https://github.com/projectkudu/kudu/wiki/Azure-Web-App-sandbox) says Windows App Service blocks most Win32k (User32/GDI32) calls, and that HTML-to-PDF libraries relying on them do not work. It also says:
- All processes in the sandbox share one memory quota, so the library competes with CM for memory.
- Windows *container* web apps are not subject to these restrictions. None of yours are containers.
- Custom fonts failed in wkhtmltopdf-based tools. Your theme uses web fonts, so check fonts in any trial.

### Candidates (from documentation only, nothing tested)

| Library | Windows App Service | Notes |
|---|---|---|
| [EvoPDF Next](https://www.evopdf.com/azure-html-to-pdf-converter.aspx) | Vendor says yes, using a Chromium build integrated into the library. B1 minimum, P1v3 or higher for production. Azure's sandbox page also lists EvoPDF as supported (older page). | .NET Framework 4.6.2+. [PDF/UA from HTML](http://ns2.evopdf.com/pdf-ua-dotnet) (vendor claim). Vendor-listed price: perpetual from 450 USD, or 1,200 with redistribution and unlimited servers. Check how servers are counted. |
| [IronPDF](https://ironpdf.com/troubleshooting/azure/) | Vendor says yes on Basic B1 or higher, using an embedded Chromium engine. | .NET Framework 4.6.2+. [PDF/UA output](https://www.ironpdf.com/tutorials/pdf-accessibility-csharp-pdfua-tutorial/) (vendor claim). Pricing not checked. |
| SelectPdf | Sources conflict: a [Microsoft Q&A answer](https://learn.microsoft.com/en-us/answers/questions/514432/selectpdf-error-on-azure-app-service) says its Chromium engine works on Basic and above; a [Stack Overflow answer](https://stackoverflow.com/questions/75198225/selectpdf-htmlpdf-converthtmlstring-method-failing-in-azure-error-occurred-tryi) quotes their support saying it is not officially supported on Azure. | Needs vendor confirmation. |
| Syncfusion | No. Their [docs](https://help.syncfusion.com/document-processing/pdf/conversions/html-to-pdf/net/azure) say the Blink converter is not supported on Windows App Service because of the GDI restriction. | Ruled out. |
| PuppeteerSharp / Playwright | Poor fit. They need a self-managed Chromium inside the sandbox, and forum answers report failures. | Ruled out. |

### What the JSON contains and lacks

Measured on an earlier eBook sample (26 components, 105 KB):
- 11 components have empty contents, including the section and column wrappers. The grid markup (container, row, column classes) is not in the JSON.
- Most of the size is site chrome: the nav appears twice (desktop and mobile, about 11 KB each), plus search, footer, social links and a modal. The page body is about 9 KB.
- There is no `<head>`, CSS, font or JS. Image URLs are site-relative.
- Scriban output is escaped twice and needs a second decode. The footer embeds JSON and GUID references instead of finished HTML.
- On `what-can-i-make`, the live page shows a checkmark icon where the JSON path leaves the literal text `Icons.CheckmarkFilled` (an unresolved SXA variable).
- Chrome can be left out by choosing components, instead of hiding it with CSS.

### The CSS question

The JSON has no styling. Options:
1. Use a plain print stylesheet, as the coworker's repo does (Option C). The result is a clean document, not the site's look.
2. Link the site's theme CSS into the HTML you build. **Not tested.** Theme CSS that depends on the missing grid wrappers will not reproduce the columns, and the theme's `@media print` rules (such as the one hiding the hero) would apply.
3. Skip the JSON and give the library the page URL, as in the Gotenberg demo.

### Unknowns
- Whether the library runs reliably in your App Service plan and tier. This needs a trial in the dev App Service.
- Whether code running in CM can read draft pages without an HTTP login. It should, since the pipeline runs inside CM, but this is unverified.
- Memory use for a 20 to 30 page batch inside CM's shared quota.
- Whether each library can merge PDFs and add bookmarks (the eBook case).
- How many license servers you need, given production plus lower environments.

---

## C. Button in the visitor's browser (`emi-generate-pdf-0.1.0`)

**How it works.**
1. A script file (`ebook-pdf.min.js`, 12 KB) is added to the site as an Associated Asset.
2. A button with `data-ebook-pdf` and `data-landing-url` is added through a rendering variant.
3. On click, the visitor's browser requests the landing page and every child page with `Content-Type: application/json`, which selects the JSON device. The library reads the landing page's Page List to find the children.
4. It builds one document (cover, linked table of contents, one chapter per page) in a hidden iframe and opens the print dialog. The visitor chooses "Save as PDF".

Nothing runs on the server and nothing leaves the browser. There is no engine, no license and no new hosting. The same code also ships as a Node CLI that prints with headless Edge or Chrome.

**What was tested.** The Node CLI with Node 22.19.0 and Edge, on `ebook-landing-page`. The button and print dialog flow was **not** exercised in a page.
- The JSON device answers a plain GET without a login: HTTP 200, `application/json`, 135 KB. The same URL returns 411 KB of HTML without the header.
- The tool fetched all 5 child pages and wrote a PDF of about 9 pages (counted from PDF markers). The PDF is tagged, has an outline, and has `lang=en`. Output is saved as `output\emi-ebook.pdf` and `output\emi-ebook.html`.
- Four of the five child pages have no body text, so those chapters are empty. That is the content, not a tool fault.
- Gaps seen: the literal text `Icons.CheckmarkFilled`, and the in-page search box and its two buttons stay in the PDF as dead controls.

**Limits.**
- **eBooks only today.** It depends on the landing page's Page List and on an eBook-style hero. Handling any page needs a single-page mode (not built).
- **Plain look.** It ignores the site's CSS and uses its own stylesheet (`src/core/document.ts`, with an `extraCss` hook).
- **Manual save.** The visitor picks "Save as PDF". Nothing is stored or attached by the system.
- **Browser variance.** The README says Chrome and Edge tag the PDF well and Firefox and Safari less. The running footer relies on CSS page margin boxes, which I only checked for Chrome and Edge.
- **Build.** Rebuilding needs Bun. The built `dist/` folder runs with Node 18.17 or newer.

---

## Ribbon button idea

The plan is a ribbon button that takes the selected page's URL instead of typing it in a command. The project already has this pattern in `src/eMi.Sitecore/Commands`: `UnpublishItem` reads `context.Items[0]`, and `GoToHelp` opens a URL with `SheerResponse.Eval("window.open(...)")`. None of the wiring below is built.

| Option | What the ribbon command would do | Catch |
|---|---|---|
| A. Gotenberg | Call the Gotenberg HTTP API with the page URL and return the PDF. | Needs the Linux service. Draft pages need authentication passed to Gotenberg. |
| B. Library | Call the library in-process with the URL or the JSON and return the PDF. | Needs the license and the sandbox trial. |
| C. Browser | Open the page in a new tab, as `GoToHelp` does, so the visitor's script can run. | The script only starts from a click on a `[data-ebook-pdf]` button. A trigger such as a query parameter would need to be added. |
| C. Node CLI | Run `node dist\cli.js <url>`. | **Not a fit for a ribbon command on App Service.** It needs Node and Edge or Chrome on the machine, and I did not test headless Edge inside the Windows App Service sandbox. It suits a dev machine or a build agent. |

---

## Side by side

| | A. Gotenberg | B. Library in CM | C. Browser button |
|---|---|---|---|
| New hosting | Linux service | None | None |
| License cost | None | Commercial | None |
| Look | Closest to the site | Your own template and CSS | Plain document |
| Stored PDF | Yes | Yes | No, the visitor saves it |
| Drafts and login | Credentials must be passed | In-process, unverified | Uses the visitor's session (published pages on the public site) |
| Multi-page (eBook) | Merge and bookmarks proven | Merge support unverified | Built in |
| Accessibility evidence | Tagged PDF confirmed; PDF/UA unverified | Vendor PDF/UA claims, unverified | Tagged, outline and `lang` confirmed in headless Edge |
| Content stays in environment | Yes, if self-hosted | Yes | Yes |
| Main risk | Hosting | Sandbox, licensing, memory | Scope, look, manual step |

## Open questions

1. Must the system generate and store the PDF (attach it, batch it), or is a visitor saving one enough? This decides between C and A or B.
2. Is the eBook the only use case, or any page? Option C needs more work for any page.
3. Is a plain document look acceptable, or must the PDF match the site?
4. What is the accessibility target (tagged, PDF/UA conformant)? Nothing has been validated with veraPDF yet.
5. Do draft or unpublished pages need PDFs?
6. Which App Service tier hosts CM in each environment, and what is the license budget?

## Suggested next steps

1. Answer questions 1 to 3 with the architect.
2. For B, trial EvoPDF or IronPDF in the dev App Service in URL mode on the five component pages and the eBook. Check fonts, memory, tier, merge and PDF/UA.
3. For C, add a single-page mode, test the real button in Chrome, Edge, Firefox and Safari, and fix the icon text and dead controls.
4. For A, decide the Linux hosting question only if the other two fail.

## Verified and unverified

**Verified by running or fetching:**
- The Gotenberg demo results above.
- The JSON device answering on `cmstest.michigan.gov`.
- The coworker's CLI producing a PDF from the eBook.

**From documentation or vendor pages only:**
- Every claim in the Option B candidate table.
- The Azure sandbox behaviour.

**Not verified:**
- Any library running on your App Service.
- The browser button flow.
- The theme-CSS idea.
- Ribbon wiring.

## Sources

- [Azure App Service sandbox](https://github.com/projectkudu/kudu/wiki/Azure-Web-App-sandbox)
- [Syncfusion HTML to PDF on Azure](https://help.syncfusion.com/document-processing/pdf/conversions/html-to-pdf/net/azure)
- [IronPDF on Azure](https://ironpdf.com/troubleshooting/azure/) and [PDF/UA](https://www.ironpdf.com/tutorials/pdf-accessibility-csharp-pdfua-tutorial/)
- [EvoPDF on Azure](https://www.evopdf.com/azure-html-to-pdf-converter.aspx) and [PDF/UA](http://ns2.evopdf.com/pdf-ua-dotnet)
- [SXA Layout Service JSON](https://doc.sitecore.com/xp/en/developers/sxa/103/sitecore-experience-accelerator/en/use-the-sxa-layout-service-to-model-your-pages-in-json.html)
- [Gotenberg: how it works](https://gotenberg.dev/docs/about), [merge](https://gotenberg.dev/docs/pdf/merge) and [releases](https://github.com/gotenberg/gotenberg/releases)
- [litho licensing note](https://github.com/gotenberg/litho)

_Vendor and forum content was summarised in my own words._
