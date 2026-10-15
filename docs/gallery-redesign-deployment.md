# Customer Gallery — Event release and rollback (October 16, 2026)

**Released October 16 with owner approval after final candidate Production Gate passed.**

## Verified current deployment

- Public front door: `https://gallery.madetokeepstudios.workers.dev/`. Its read-only
  `?diagnostic=proxy` reports healthy upstream and backend
  `made-to-keep-gallery-v3-stills-20261016`.
- Existing Apps Script project: **Pocket Pixels Gallery Backend**, signed-in Pocket Pixels
  account, project ID `1EdArbkIBJzbdyuyqrDcbp898FfudGv2TbrlFNNYrMoiAhkStzc7qJg5h`.
- Manage deployments confirms the existing Web App is **version 23** (October 16).
  Version 22 (October 9) is retained for rollback.
  Its `/exec` URL exactly matches `PocketPixelsBooth/Info.plist` and the Worker configuration.
  Execute as owner / Anyone access are already configured; preserve both.
- The October 14 editorial source was never deployed. The active page is generated in
  `Code.gs`; replacing the legacy `Index.html` will not release this design.
- Legacy documented front door `https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/`
  returns NXDOMAIN from both 1.1.1.1 and 8.8.8.8. Historical tokens remain supported in source, but
  availability of that old hostname is **unverified and requires account/routing investigation**.
  Do not rename, delete, or redirect either front door while resolving this.
- Authenticated existing Cloudflare CLI access confirms account
  `f4119288ab0fe1f5c0e2f37b86735236`, subdomain `madetokeepstudios`, Worker `gallery`,
  no custom domains and no legacy gallery Worker. The existing account cannot retain the current
  workers.dev host while also being renamed to the former subdomain. No subdomain change occurred.
- Live Worker rollback version: `c5ccf383-0010-48f1-9fd7-0eb17679078c`. Configuration
  preserves production compatibility date `2026-10-08`, enabled workers.dev and disabled preview URLs.
  Deploy with `--keep-vars`; the existing origin is the sole binding. Dry run and 29 tests pass.
- Released Worker: `aabb760a-95e1-4964-b698-39c7aff376d6`. Live API comparison confirms prior
  bindings, compatibility flags/date, observability, tail consumers and logpush are preserved.
  Observability was briefly disabled by the initial CLI upload and immediately restored; the
  complete prior settings are now explicit in `wrangler.toml`.
- Public proxy health confirms v3/upstream 200; invalid/pending native URLSession reads pass.
  A historical token on the current host loads its photo and both receipts, including lightbox.
  Owner confirmed a fresh session on iPhone Safari after release: no sign-in, all photos and both
  receipts visible, individual photo saving passed. Android Chrome, native bulk sharing and a
  physical offline-recovery drill remain unverified.

## Released changes

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
Fresh-gallery access and individual saving passed on real iPhone Safari by owner observation.
Android Chrome and native bulk share sheets still require a phone check.

## Authorized release sequence

1. Owner approval received; retain Apps Script **version 22** as the rollback version.
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
version `c5ccf383-0010-48f1-9fd7-0eb17679078c` using Cloudflare deployment rollback
(same Worker, account and routes). The prior
repository Worker is at `9dfd258`; restoring it only changes the internal cache namespace.
Recheck proxy diagnostics, a consented diagnostic gallery and private historical links.
No data migration or file deletion is part of release or rollback. New still-only payloads were
already supported by version 22, so the new iPad candidate remains compatible after rollback.
