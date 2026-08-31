# Pocket Pixels Cloudflare Gallery Proxy

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
6. Set Apps Script property `POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL` to the final Worker base URL, including a trailing slash.
7. Set the iPad app `POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL` Info.plist value to the same Worker base URL.

The customer browser must stay on the Worker/custom domain and must never navigate to `script.google.com`.
