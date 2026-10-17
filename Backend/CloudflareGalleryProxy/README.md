# Made to Keep Studios Cloudflare Gallery Proxy

This Worker is the browser-neutral public front door for customer gallery GET requests.

Customer browsers open:

```text
https://gallery.madetokeepstudios.workers.dev/?g=<64-lowercase-hex-token>
```

The Worker fetches the private Apps Script gallery renderer server-to-server:

```text
https://script.google.com/macros/s/<current-deployment-id>/exec?proxy=raw&g=<token>
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
3. Confirm the existing account/Worker and deploy with `wrangler deploy --keep-vars` to retain configured variables.
4. Test the temporary `workers.dev` URL with a new gallery token.
5. The current production URL is `https://gallery.madetokeepstudios.workers.dev/`. The legacy hostname currently fails DNS; see the release record below. Preserve established URLs and do not create or rename a Worker for this redesign.
6. Set Apps Script property `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` (or the legacy `POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL`) to the final Worker base URL, including a trailing slash.
7. Set the iPad app's `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` build setting (or the legacy Info.plist key) to the same Worker base URL.

The customer browser must stay on the Worker/custom domain and must never navigate to `script.google.com`.

## Current Made to Keep front door and legacy compatibility

The app currently uses `https://gallery.madetokeepstudios.workers.dev/`. The checked-in
`wrangler.toml` names `gallery`; it does not define a `madetokeep` environment. Confirm the
Cloudflare account and existing Worker before publishing. Do not create a replacement Worker
or change public routes to release an HTML update.

The legacy `https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/` address remains in
historical receipts and app compatibility configuration. It returned NXDOMAIN from both public resolvers during the
October 16 inspection; its live routing needs investigation. Token compatibility tests do not
prove that a hostname is reachable.

Both front doors must continue to use the same existing Apps Script `/exec` deployment.
`MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` takes precedence for new upload response URLs;
the legacy property remains a fallback. Existing sessions, archives, recovery records and queued
uploads keep their frozen URL. New uploads contain still photographs and both receipts.
Historical optional GIF assets remain accepted and stored.

See [verified deployment targets, owner approval, validation and rollback](../../docs/gallery-redesign-deployment.md).
