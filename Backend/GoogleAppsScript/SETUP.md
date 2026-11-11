# Made to Keep Studios Google Apps Script Setup

This backend receives gallery uploads from the iPad, stores them in one dedicated Google Drive folder, and renders private-by-link customer galleries for the Cloudflare Worker front door.

For production updates, use the existing project and deployment described in [the release record](../../docs/gallery-redesign-deployment.md). The steps below also describe initial setup; do not create a replacement project to update production.

## Resumable transport update (11 November 2026)

The candidate backend is `made-to-keep-gallery-v10-resumable-20261111`. Install
**both** `Code.gs` and `ResumableUploads.gs`; preserve the existing manifest,
properties, root folder, device token, deployment ID and access configuration.
The version-30 production deployment remains the rollback target. Source in the
editor (HEAD) is separate from the active versioned deployment.

Before activating this backend, the existing owner must run
`enableResumableUploadsForOwner` in the editor and complete Google's authorization
if requested. This exercises `UrlFetchApp` and the Drive REST API before setting
`MTK_RESUMABLE_UPLOADS_ENABLED=true`. Do not advertise support or update the active
deployment until this succeeds. No Advanced Drive service or new OAuth client is
needed; broad Google access remains exclusively on the server.

Use an isolated synthetic gallery to verify initialization, a lost chunk response,
server-offset recovery, finalization, the existing Worker readiness endpoint and
the complete public page. Check existing galleries before and after release.
Then update the **existing** Web App deployment to a validated version and verify
`?diagnostic=phase6c`: the new version and `drive-resumable-v1` must both appear.
Never replace the production deployment URL to release this change.

The backend reserves stable Drive file IDs in private journals under
`.gallery-upload-journals`, outside customer gallery folders. The iPad receives
per-file resumable session capabilities, never a broad Google OAuth token.
Manifests are published only after exact filename, parent, size, type and SHA-256
checks. Existing schemas 1–4 and historical GIFs remain supported. Current schema
4 stores the color receipt and derives the monochrome presentation as before.

Do not delete incomplete galleries, private journals, active-transfer properties
or local media during a rollout/rollback. Disabling the capability stops fresh
resumable choices; clients with a saved transfer journal retain their protocol and
media. Finish those transfers with the compatible backend before retiring it.
Version 30 continues to read published galleries, but cannot finish a new binary
transfer. See [validation and exact rollback procedure](../../docs/gallery-delivery-reliability-2026-11-11.md).

## Setup Steps

1. In Google Drive, create a dedicated folder named something like `Pocket Pixels Galleries`.
2. Open that folder and copy its folder ID from the URL. It is the long value after `/folders/`.
3. Go to `https://script.google.com`.
4. Create a new standalone Apps Script project.
5. Replace the default `Code.gs` contents with `Backend/GoogleAppsScript/Code.gs` and add `Backend/GoogleAppsScript/ResumableUploads.gs`.
6. Do not add an `Index.html` file. The customer gallery page is inline inside `Code.gs`.
7. Create a long random device token, at least 32 characters. Keep it private.
8. In Apps Script, open Project Settings, then Script Properties.
9. Add `POCKET_PIXELS_ROOT_FOLDER_ID` with the dedicated Drive folder ID.
10. Add `POCKET_PIXELS_DEVICE_TOKEN` with the random device upload token.
11. Add `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` with the Cloudflare Worker customer base URL: `https://gallery.madetokeepstudios.workers.dev/`.
12. In the editor, select `runPocketPixelsSelfTest` and run it.
13. Complete Google’s authorization flow for the script. This authorizes the script to create and read files as the selected Google account.
14. Deploy as a versioned Web App.
15. Choose `Execute as: Me`.
16. Choose `Who has access: Anyone`. Do not use `Anyone with Google account`, because the Worker must fetch as anonymous.
17. Copy the canonical production Web App URL ending in `/exec`: `https://script.google.com/macros/s/{deploymentID}/exec`. Do not use `/dev`, `/library/`, `/u/0`, `/u/1`, `/u/2`, or editor URLs.
18. Put the `/exec` URL into the iOS app’s `GOOGLE_GALLERY_WEB_APP_URL` Info.plist value. This is the backend upload URL only.
19. Put the Worker customer base URL into the iOS app’s `POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL` Info.plist value.
20. Build and run the iPad app in DEBUG.
21. Open the `Cloud Test` tab and enter the same device token. The token is saved to the iPad Keychain and is not stored in source code.
22. Select exactly three test photos and build the receipt preview.
23. Confirm Cloud Test shows a redacted gallery token, Worker customer gallery URL, and QR preview before upload. The URL must look like `https://gallery.madetokeepstudios.workers.dev/?g={galleryToken}` and must not contain `script.google.com`.
24. Open the pre-upload gallery link. A valid unused token should show the branded pending state.
25. Upload one test gallery.
26. Confirm exactly one folder appears inside the dedicated Pocket Pixels root folder.
27. Confirm that folder is named `gallery-{galleryToken}` and contains the sequenced photos, `receipt-color.jpg`, `receipt-bw.png`, optional `session.gif`, and `manifest.json`.
28. Confirm `manifest.json` lists the exact stored assets and matches the uploaded schema. Current schema 4 omits the redundant thermal upload; older schemas retain their expected assets. New still-photo uploads omit the GIF; historical payloads may include `gif: "session.gif"`.
29. Open the same Worker gallery link in Safari and confirm all gallery images appear.
30. Tap `Retry Same Upload` in Cloud Test and confirm it returns an existing completed gallery without creating a second folder or changing the customer gallery URL.
31. To update this Phase 6C backend, use `Deploy -> Manage deployments -> Edit -> New version -> Deploy`. Preserve the existing Web App deployment so the backend `/exec` URL does not change. Do not create a new deployment.
32. Open `?diagnostic=phase6c` on the deployed `/exec` URL and confirm `backendVersion` is the version being released. The resumable candidate is `made-to-keep-gallery-v10-resumable-20261111`; the release record identifies what is actually active.
33. Open a completed Worker gallery URL in iPhone Safari, iPhone Chrome, iPad Safari, iPad Chrome, desktop Safari, desktop Chrome signed out, desktop Chrome Incognito, Brave, and normal desktop Chrome with multiple Google accounts signed in.
34. Confirm the browser address bar remains on the Worker/custom gallery domain and never navigates to `script.google.com/macros/u/<number>/`.

## Made to Keep Gallery Front Door (Phase 2)

- `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` is the preferred Script Property for the customer gallery front door used in new upload responses.
- When it is unset or blank, `POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL` is used. Do not delete or rename the legacy property; existing deployments rely on it.
- A present but invalid Made to Keep value (not HTTPS, or `script.google.com`) fails uploads instead of silently falling back, so misconfiguration is visible.
- Gallery lookup is by token only. Historical tokens and new tokens resolve to the same Drive storage. The old hostname currently fails DNS; token compatibility does not prove that old printed hostnames are reachable. See the release record.
- Run `checkCustomerGalleryConfig` to see which property is active (`propertyName`, `usesLegacyProperty`) without logging the value.
- Only set the Made to Keep property after the new Worker/front door is deployed and verified. See `Backend/CloudflareGalleryProxy/README.md` for the full deployment order.

## Security Notes

- The iPad never gets direct Google Drive credentials or unrestricted Drive access.
- Uploads require `POCKET_PIXELS_DEVICE_TOKEN`.
- Customer gallery URLs are generated from `MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL` when set, otherwise from the legacy `POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL`.
- Customer browsers open the Cloudflare Worker URL only; they do not navigate directly to Apps Script.
- Do not post the device token publicly.
- Anyone possessing the device token could attempt uploads.
- Customer gallery URLs contain long random client-generated tokens. Anyone possessing a gallery URL can view that gallery.
- Gallery pages are marked `noindex, nofollow`, but that is not authentication.
- The script only searches inside the configured Pocket Pixels root folder.
- The root folder ID and device token are not written to manifests or returned to gallery viewers.

## Retention

- Successful galleries never expire automatically.
- There is no time-based cleanup trigger.
- Pocket Pixels must manually remove galleries when desired.
- No cleanup trigger is installed.
- The backend does not automatically delete, trash, or move completed or incomplete gallery folders.

## Failure Behavior

- Upload validation happens before folders or files are created.
- If saving fails midway, the incomplete folder is preserved for manual inspection.
- Repeating the same `galleryToken` and `sessionID` is idempotent.
- Previously completed galleries are not modified.
- The iPad first reconciles ambiguous deliveries through the saved public URL. Confirmed accepted galleries use GET-only recovery; incomplete resumable assets query Google's confirmed offset before sending remaining bytes. Local files remain until public verification and durable local proof succeed.

## Important Limitations

- If the Google account, root folder, Apps Script project, Web App deployment, or Cloudflare Worker route is removed or transferred, existing gallery links may break.
- Apps Script quotas apply to daily executions, Drive reads/writes, and response sizes.
- The gallery serves images through inline Apps Script data URLs in a single self-contained HTML response to avoid making the Drive root folder public and to avoid browser-fragile per-image script calls.
- Google multi-login is not reliable for customer-facing Apps Script URLs. Do not put `script.google.com` links in QR codes, receipts, sharing flows, or the Thank You screen.
