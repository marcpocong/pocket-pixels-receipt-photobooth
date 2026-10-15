# Customer Gallery — Event release and rollback (October 16, 2026)

**Prepared in source; NOT deployed. Owner approval is required before any live update.**

## Verified current deployment

- Public front door: `https://gallery.madetokeepstudios.workers.dev/`. Its read-only
  `?diagnostic=proxy` reports healthy upstream and backend
  `made-to-keep-gallery-v2-optional-gif-20261009`.
- Existing Apps Script project: **Pocket Pixels Gallery Backend**, signed-in Pocket Pixels
  account, project ID `1EdArbkIBJzbdyuyqrDcbp898FfudGv2TbrlFNNYrMoiAhkStzc7qJg5h`.
- Manage deployments confirms the existing Web App is **version 22** (October 9).
  Its `/exec` URL exactly matches `PocketPixelsBooth/Info.plist` and the Worker configuration.
  Execute as owner / Anyone access are already configured; preserve both.
- The October 14 editorial source was never deployed. The active page is generated in
  `Code.gs`; replacing the legacy `Index.html` will not release this design.
- Legacy documented front door `https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/`
  returns NXDOMAIN from both 1.1.1.1 and 8.8.8.8. Historical tokens remain supported in source, but
  availability of that old hostname is **unverified and requires account/routing investigation**.
  Do not rename, delete, or redirect either front door while resolving this.
- Cloudflare browser inspection stopped at existing-account sign-in; no account settings changed.

## Prepared changes

`Code.gs` backend version: `made-to-keep-gallery-v3-stills-20261016`.
Warm ivory / burgundy editorial page, centered wordmark, oversized headline, primary Save All
Photos action, still-photo gallery, both receipts, and static paper-strip ornaments on wide
screens. Historical GIFs stay stored and accepted by upload/manifests but are not loaded or
presented in the new customer page. Pending, invalid and temporary failure pages retain the
existing bounded polling, privacy and error behavior.

Worker cache version: `made-to-keep-stills-20261016`. Only the internal completed-page cache
key changes. Public QR URLs, authentication, token lookup, manifest schema and Drive data do not.

## Validation before release

```sh
node Backend/GoogleAppsScript/GridSixValidation.test.cjs --fixtures
(cd Backend/CloudflareGalleryProxy && npm test)
```

Run the iOS gate, including `GalleryBrowserLayoutTests`, after generating these synthetic
fixtures. Local WebKit tests cover 1/2/3/4/6 photos at 320/375/390/430/768/1024/1440 px.
Real iPhone Safari and Android Chrome share/save flows still require a phone check.

## Authorized release sequence

1. Confirm owner approval and retain Apps Script **version 22** as the rollback version.
2. In the existing project editor, replace **Code.gs** with validated source. Do not run upload
   functions or edit script properties. Browser access to this exact project is available;
   manual owner copying is not a prerequisite.
3. Deploy → Manage deployments → edit the **existing active Web App** → New version → Deploy.
   Never create a deployment or change its `/exec` URL/access/owner.
4. Check `?diagnostic=phase6c` on the existing `/exec` URL; expect the new backend version.
5. Before updating Workers, verify the Cloudflare account/subdomain and existing Worker name.
   Current `wrangler.toml` names **gallery**, matching the active public host. It has **no
   `madetokeep` environment**; the former `--env madetokeep` instructions were incorrect.
   Update the existing `gallery` Worker in the verified account. Update any independently
   confirmed legacy Worker with the same source; do not guess a target or create replacements.
6. Check the public proxy diagnostic again. Check a consented diagnostic gallery plus a known
   historical gallery privately on both confirmed front doors. Never log or publish their tokens.
7. Confirm all photos, both receipts, individual viewing/saving, sharing and Save All; test
   iPhone Safari / Android Chrome. Unsupported bulk saving must guide guests to individual Save.
8. Test a fresh random valid-but-unused token (pending) and an invalid token (invalid). Repeated
   completed-page reads should show cache HIT. No payment or customer data write is needed.

Apps Script alone updates pages after existing edge caches expire (up to one hour). The Worker
cache bump makes the switch immediate. Do not change the PayMongo Worker for this release.

## Rollback

Edit the **same** Apps Script deployment back to **version 22**. Restore the previous Worker
version using Cloudflare deployment rollback (same Worker, account and routes). The prior
repository Worker is at `9dfd258`; restoring it only changes the internal cache namespace.
Recheck proxy diagnostics, a consented diagnostic gallery and private historical links.
No data migration or file deletion is part of release or rollback. New still-only payloads were
already supported by version 22, so the new iPad candidate remains compatible after rollback.
