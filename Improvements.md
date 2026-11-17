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


### 3. Default PDF page width and height

`Test-Gotenberg.ps1` sets a custom page size (`$paperWidth = '1280px'`, `$paperHeight = '1810px'`) instead of Gotenberg's default Letter. On Letter, Chromium lays the page out at about 740 CSS pixels wide, which triggers the site's tablet/mobile breakpoint and stacks side-by-side items. The wider page lays out like a desktop screen, and this makes the PDFs look significantly better.

These values are defaults chosen for the POC. They can be changed to whatever size the business approves.

- Confirm the approved page size (width and height, or a standard size such as A4 or Letter) and update `$paperWidth` and `$paperHeight` in the script.
- Consider making the size a script parameter, so it can change without editing the script.

### 4. Hero is hidden in print mode

The site's print stylesheet intentionally hides the hero section. Not sure why

```css
@media print {
    .hero-image__section section {
        display: none !important;
    }
}
```

With `emulatedMediaType=print` the PDF shows the plain `print-only` title instead of the hero banner. Switching to `screen` brings the hero back but leaves the accordions collapsed.

Things to look into:

- Ask team why the hero is hidden in print, and whether it should show in PDFs.
- Decide whether PDFs should include the hero, or keep the print behavior.
- If the hero should show, either change the print stylesheet on the site, override the rule in the script, or switch to `emulatedMediaType=screen` and expand the accordions with injected CSS.

### 5. PDF/UA accessibility with a remediate stage

The script already sends `nativeTaggedPdf=true`, so Chromium writes a tag structure (headings, lists, tables, images) from the page's HTML. A tagged PDF is not the same as a PDF/UA-conformant one.

Gotenberg 9 can add a `remediate` stage to the request, which repairs the PDF toward a profile such as PDF/UA-1:

```
--form 'stages=[{"op":"remediate","profile":"PDF/UA-1"}]'
```

The response headers report how much it couldn't fix (`Gotenberg-Remediation-Residual`). This is a repair step, not a validator. A separate tool such as [veraPDF](https://verapdf.org/) is still needed to check conformance. Accessibility is the business driver, so this is worth testing.

Things to look into:

- Add an optional parameter to `Test-Gotenberg.ps1` that sends the remediate stage (untested so far).
- Expect imperfect results. The output depends on the site's markup, such as alt text, heading order, and table structure.

### 6. Hide site chrome (sitewide alert, main nav, etc.) from the PDF

The generated PDFs currently include the sitewide alert and the main navigation. These can be hidden or removed from the PDF. Whether they should be is a business decision, so the script does not do it yet. More elements will likely be added to this list over time (for example the header, footer, or breadcrumb).

To hide them, define this variable in `Test-Gotenberg.ps1`:

```powershell
# CSS for site chrome (page elements that are not content) to leave out of the PDF.
# Add more selectors to this list as needed. Currently it hides:
#  - Alerts (sitewide and page-level): the section with an alertid attribute.
#  - Main nav: the whole wrapper section (":has"), so no empty gap is left behind, plus the
#    desktop menu, mobile menu and megamenu panels by id/class as a fallback.
# No single quotes allowed in this string: it is placed inside a JavaScript string below.
$hideChromeCss = "section.important-information-box__section[alertid] { display: none !important; } section.component-wrapper:has(#menuA), section.component-wrapper:has(#menuAmobile), #menuA, #menuAmobile, .megamenu, .navigation-main, .navigation-toggle { display: none !important; }"
```

Then add it to the CSS that the script injects. In `$lazyImageExpression`, change `s.textContent = '$printFixCss';` to:

```powershell
s.textContent = '$printFixCss $hideChromeCss';
```

Things to look into:

- business decision on which elements to leave out of the PDF, and add each one to `$hideChromeCss`.
- We could add the site-side option print rule that hides these elements, which would also affect browser printing.
```css
@media print {
    .{Sitewide Alert/BreadCrumb/Whatever should be hidden} section {
        display: none !important;
    }
}
```
