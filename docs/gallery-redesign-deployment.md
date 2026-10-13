# Customer Gallery Redesign — Deployment and Rollback

Status: **implemented in Git, not deployed.** Production Apps Script and both Cloudflare
Workers still serve the previous gallery until the owner runs the steps below.

## What changes

| Component | Change | Customer URL impact |
| --- | --- | --- |
| `Backend/GoogleAppsScript/Code.gs` | New gallery page, pending / invalid / unavailable pages. `BACKEND_VERSION` is now `made-to-keep-gallery-v2-editorial-20261014`. | None. Same `/exec` deployment, same token lookup. |
| `Backend/CloudflareGalleryProxy/src/index.js` | `COMPLETED_GALLERY_CACHE_VERSION` is now `made-to-keep-editorial-20261014` so cached old pages are not served for their remaining edge TTL. | None. The cache key is internal; QR URLs never contain it. |

Unchanged: token format and validation, upload API, manifest schema, Drive layout, the
`data-pocket-pixels-gallery-status="complete"` marker, Worker upstream allow-list, redirect
handling, security headers, and both front doors.

## Before deploying

```sh
node Backend/GoogleAppsScript/GridSixValidation.test.cjs
(cd Backend/CloudflareGalleryProxy && npm test)
```

Keep a known completed gallery token and a known pending token ready for checks. Do not paste
tokens into chat, tickets or logs.

## Deploy (order matters)

1. **Apps Script** — open the existing project, replace `Code.gs` with the repository version,
   then `Deploy → Manage deployments → Edit (existing Web App) → Version: New version → Deploy`.
   Never create a new deployment: that would change the `/exec` URL.
2. Open `<exec URL>?diagnostic=phase6c` and confirm
   `backendVersion` is `made-to-keep-gallery-v2-editorial-20261014`.
3. **Legacy Worker** (keeps every printed QR working) — publish the repository's `src/index.js`
   to the existing `pocket-pixels-gallery` Worker the same way it was last published (the
   top-level `wrangler.toml` in this repository names the Worker `gallery`, so confirm the target
   name before running `wrangler deploy`; the dashboard editor is the safest option). Do not
   rename, delete or re-route it.
4. **Made to Keep Worker** (if already deployed): `npx wrangler deploy --env madetokeep`.
5. Verify on a phone and a desktop:
   - `https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?diagnostic=proxy` → `ok: true`
     and the new `backendVersion`.
   - `https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=<completed token>` → new
     design, photos, GIF (if the session had one), receipt; Save and Share work.
   - Same token on the Made to Keep front door, if deployed.
   - A pending token shows "your photos are still being prepared." and stops checking after
     about two minutes.
   - `?g=not-a-token` shows the invalid-link page.
   - An old QR from before the rebrand still opens.

Steps 1–2 alone already show the new design once cached copies expire (up to one hour).
Steps 3–4 only make the switch immediate.

## Rollback

1. Apps Script: `Manage deployments → Edit → Version` → choose the previous version → `Deploy`.
   The previous source is `Backend/GoogleAppsScript/Code.gs` at commit
   `06f63f643d60542a7da5ad3bad96bd3fc843497f`.
2. Workers: redeploy the previous `src/index.js` (same commit range) or roll back in the
   Cloudflare dashboard (`Deployments → Rollback`). The only Worker difference is the cache
   version string, so rolling back the Worker is optional.
3. Re-run the verification links above.

No data migration is involved in either direction; galleries, tokens and printed QR codes are
untouched by deploys and rollbacks.

## Browser support notes

- Saving: iPhone/iPad open the share sheet, where **Save Image** adds the photo or animated GIF
  to Photos. Android and desktop download the original file. The page never claims a file was
  saved to Photos.
- **Save All Photos**: phones and tablets use a multi-file share sheet when supported; desktops
  download each photo; browsers that support neither hide the button and point to per-photo Save.
- Share buttons appear only where the browser can share files.
- Reduced Motion: the GIF shows its first frame with a Play button instead of autoplaying.
- Verified with Chrome DevTools emulation at 320, 375, 390, 430, 768, 1024 and 1440 px. Real
  iPhone Safari, Android Chrome, desktop Safari, Edge, Firefox and in-app browsers still need a
  manual pass after deployment.
