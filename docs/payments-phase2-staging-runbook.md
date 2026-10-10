# Test-mode staging runbook

> **Superseded by `docs/payments-phase3-test-staging-runbook.md`.** Phase 3 added the explicit `[env.test]` these commands assumed (Phase 2's config had none, so `--env test` failed).

No command below was executed against Cloudflare or PayMongo.

1. Create a dedicated test D1 database; review then apply migrations with `wrangler d1 migrations apply <TEST_DB> --env test`.
2. Configure only test secrets: `wrangler secret put PAYMONGO_SECRET_KEY_TEST` and `PAYMONGO_WEBHOOK_SECRET_TEST`; configure the public key only if required by the current attach flow. Note that secret commands may publish a version.
3. Provision separate operator/device tokens; store the iPad device token through Keychain pairing, never Info.plist.
4. Set the HTTPS test Worker URL and `PAYMENTS_ENVIRONMENT=test` in the reviewed app configuration.
5. With explicit owner approval, deploy the test Worker and register the exact `/v1/webhooks/paymongo/test` URL. Confirm the scheduled job and diagnostics.
6. Use PayMongo’s returned `test_url` simulator for success/failure/expiry. Never scan a test QR with a live bank/e-wallet.
7. Run kill/relaunch, offline cash, delayed webhook, event pause/end, N-copy, ambiguous print, Passport, stickers and gallery tests on the iPad and VOZY G80.

Suggested local commands: `npm test`, `npm run check`, and `xcodebuild ... build-for-testing` followed separately by bounded `xcodebuild test-without-building` on a named simulator.
