# Made to Keep Studios Cloudflare Gallery Proxy

This Worker is the browser-neutral public front door for customer gallery GET requests.

Customer browsers open:

```text
https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=<64-lowercase-hex-token>
```

The Worker fetches the private Apps Script gallery renderer server-to-server:

```text
https://script.google.com/macros/s/<current-deployment-id>/exec?g=<token>
```

Uploads still go directly from the iPad to Apps Script. The Worker is not an upload endpoint.

## Required variable

`APPS_SCRIPT_GALLERY_ORIGIN`

Set it to exactly the canonical Apps Script Web App URL:

```text
https://script.google.com/macros/s/<current-deployment-id>/exec
```

Do not include `/macros/u/<number>/`, query strings, fragments, `/dev`, or any customer-controlled upstream URL.

## Local tests

```sh
npm test
```

## Deploy

1. Install or authenticate Wrangler if needed.
2. Set `APPS_SCRIPT_GALLERY_ORIGIN` in `wrangler.toml` for local testing, or configure the same variable in the Cloudflare dashboard.
3. Deploy with `wrangler deploy`.
4. Test the temporary `workers.dev` URL with a new gallery token.
5. The active temporary Worker URL is `https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/`. After verification, attach a custom domain such as `gallery.<owned-domain>` if desired.
6. Set Apps Script property `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` (or the legacy `POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL`) to the final Worker base URL, including a trailing slash.
7. Set the iPad app's `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` build setting (or the legacy Info.plist key) to the same Worker base URL.

The customer browser must stay on the Worker/custom domain and must never navigate to `script.google.com`.

## Made to Keep gallery front-door migration (Phase 2)

### Old front door (legacy, keep live)

`https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/` is already printed on customer receipts. It must stay deployed and routed as a permanent legacy alias until explicitly retired. Do not rename, delete, or re-route it. It is the existing Worker deployment; the top-level `wrangler.toml` config is left untouched.

### New front door (Made to Keep)

`wrangler.toml` defines a separate `madetokeep` environment (Worker name `made-to-keep-gallery`). It runs the same source as the legacy Worker. The Worker is host-agnostic: it only reads `?g=<token>`, always proxies to `APPS_SCRIPT_GALLERY_ORIGIN`, and caches completed galleries per public origin + token. Any hostname attached to it works. No production Made to Keep hostname is chosen in this repository yet; attach the final custom domain in Cloudflare once it is decided.

### Apps Script

Both front doors proxy the same Apps Script deployment. Gallery storage and lookup are by token only. `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` (preferred) or the legacy `POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL` only controls the URL echoed in new upload responses. The `/exec` upload URL does not change.

### iPad app

Front-door precedence for NEW sessions: operator override (Operator → Gallery Backend) → `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` Info.plist key (expanded from the build setting of the same name; blank by default) → legacy `POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL` → configuration error. Sessions that already have a gallery URL keep it: recovery snapshots, recent-session archives, reprints, and queued uploads never switch front doors. The app accepts upload responses from either front door for the same token.

### Deployment order (manual, after review)

1. Deploy the new Worker: `wrangler deploy --env madetokeep`, with `APPS_SCRIPT_GALLERY_ORIGIN` set to the same `/exec` URL as the legacy Worker. Leave the legacy Worker untouched.
2. Attach the final Made to Keep custom domain or route to the new Worker.
3. Verify `https://<new-host>/?diagnostic=proxy` and `https://<new-host>/?g=<known-test-token>`. Then verify the same token still opens on the legacy host.
4. Set Apps Script property `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` to `https://<new-host>/`.
5. Deploy the updated Apps Script as a new version of the existing deployment, so the `/exec` URL is unchanged.
6. Set the iPad build setting `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL = https://<new-host>/` (or use the operator override). Then build and install the newest iPad app.
7. Create a fresh session and confirm its QR uses the new Made to Keep host and opens the gallery, including the GIF and the Color and Thermal Receipts.
8. Open an old Pocket Pixels QR, or `https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=<old-token>`, and confirm it still opens.
