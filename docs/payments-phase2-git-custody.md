# Phase 2 Git custody

- Baseline local `main`: `934a76d350fb3e09b63941c8e6436f85ab9cd43a`.
- Existing `origin/main` reference: same SHA. A fresh fetch was attempted on 2026-10-10 but the managed environment denied writes to `.git/FETCH_HEAD`.
- Original working tree: 72 unstaged modified paths, 27 staged additions, and multiple untracked paths. It contains unrelated gallery, sticker, printer, receipt, session, and test work.
- Isolation: a no-hardlink clone was created at `/private/tmp/PocketPixelsBooth-payments-phase2.EGJPYN`, mode 0700, and branch `codex/madetokeep-payments-phase2` was created from the baseline. Only identified payment additions and surgical payment hunks were ported.
- The original working tree and index were not switched, stashed, reset, cleaned, staged, or committed.
- Recovery: delete the temporary clone only after its commit is pushed or copied elsewhere. The original repository remains the authoritative custody copy for all pre-existing changes.

Excluded from the candidate: all unrelated sticker assets/implementation, generated build output, `.env`/`.dev.vars`, credentials, customer media, and gallery route changes.
