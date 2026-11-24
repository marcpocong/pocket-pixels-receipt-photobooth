# Legacy preservation and consolidation ledger

Completed 24 November 2026 (Asia/Manila). Baseline **`8baadb77c53321c576d4fe160efc66def199b8b8`**, fetched from origin before changes. Working tree was clean; there was one worktree on `main`. No stash, reset, rebase, force-push or repository replacement was used.

## Permanent archive

- Annotated tag: **`legacy-paymongo-final`**. No previous local or remote tag existed. Remote peeled tag was verified against the full baseline SHA after push.
- [Published legacy release](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/releases/tag/legacy-paymongo-final): “Legacy PayMongo — preserved final source.” It is marked prerelease/non-latest to avoid implying a qualified stable product. Its notes explicitly identify historical status, expired provisioning, hosted-CI/hardware limits, known printer/gallery limitations and the need to preserve obligations.
- No signed app, device backup, private financial export or customer file is attached. The release preserves source; it does not certify existing production credentials or the historical build as operational.
- `main` remains the default and sole active development branch. Never move this archival tag. Future RC/stable tags must identify their own qualified source.

## Private backup and verification

Private local directory:
`/Users/marc/PrivateProjectBackups/PocketPixelsBooth-phase1-20261124-224816/`

This directory is outside the public repository, mode 0700; private files are mode 0600. Store an owner-controlled encrypted/off-device copy separately for loss of this Mac; this audit created and verified the requested local backup, not an offsite disaster-recovery service.

| Artifact | Verification / scope |
| --- | --- |
| `repository.bundle` | `git bundle create --all`, then `git bundle verify`; contains the complete reachable repository history and all 22 refs present at capture, including auxiliary refs. SHA-256 **`eb3402c20d6419670398c84b743e39d57ea0985469c9805f2426549b3eecefcf`**. |
| `restore-check.git/` | Independent mirror cloned from that bundle; `git fsck --full` passed. Complete `show-ref` output matched the captured refs byte-for-byte; restored `main` resolved to the baseline. Every removed branch tip was checked in this restored object database. This is an inert restore fixture, not a second active canonical repository. |
| `git-metadata.tar.gz` | Additional private copy of original `.git`, including local configuration and reflogs. Do not publish it or restore it blindly over an active checkout. |
| `refs-before.txt`, `branches-before.json`, `status-before.txt` | Pre-cleanup ref/tip/reachability and clean-tree evidence. `local-artifact-inventory.json` records ignored local evidence/tooling paths and sizes without copying media into Git. |
| `legacy-signed-app-expired.tgz` | Preserves the existing V5.1 signed app artifact privately. Provisioning is expired; this is historical evidence, not an installable release promise. Existing `BuildArtifacts` and caches were left intact. |
| `payments-live.sql`, `payments-test.sql` | New read-only remote exports, each restored into isolated in-memory SQLite: `integrity_check=ok`, zero foreign-key violations, 20 tables including the migration ledger. Private verification manifests contain exact hashes and sizes. No financial database was modified or overwritten. |
| Deployment/operational captures | Private Cloudflare settings, schedules, active versions, deployed payment modules, bounded Insights and operational summaries. Secret binding names were inspected; secret values were neither retrieved nor printed. These are evidence, not a complete cloud credential backup. |

The portable Git bundle predates creation of the legacy tag and Phase 1 documentation, as intended. It already contains the tag's target commit. The tag is independently stored/verified on GitHub; the final documentation commit is on canonical `main`. A post-delivery all-ref bundle can supplement, not replace, this original baseline backup.

No submodule gitlinks, `.gitmodules`, or historical attributes files were found. A scan of historical small blobs found zero Git LFS pointers. `git-lfs` itself is not installed; there is no detected LFS object set to export. No install was necessary.

Externally stored data requires separate treatment: Drive gallery/customer media and private resumable journals are not in Git and were not bulk downloaded; they remain in their existing account/folders. Provider wallet/settlement exports and Apps Script properties/credentials were not available as a complete backup. Curated reports/screenshots are tracked; ignored raw results and old expired app artifacts are local evidence. The latest legacy app plus LIVE/TEST D1 exports were separately preserved. This does not claim complete device/cloud disaster recovery.

### Restore without modifying the working repository

In a new restricted directory, verify the recorded bundle checksum and run:

```sh
git bundle verify /path/to/repository.bundle
git clone --mirror /path/to/repository.bundle restored.git
git --git-dir=restored.git fsck --full
git --git-dir=restored.git show-ref
git --git-dir=restored.git show 8baadb77c53321c576d4fe160efc66def199b8b8:AGENTS.md
```

Compare with `refs-before.txt`. Restore an individual old branch only when needed using its recorded SHA; do not recreate every obsolete active branch. Never import an old SQL dump over newer production financial history; inspect it in isolation and use a reviewed forward recovery procedure. This session's SQL restore checks made no network writes.

## Branch disposition

Fresh `git ls-remote --heads origin` showed **only `main`**. Fetch pruned a stale remote-tracking ref for an already-deleted branch; no remote branch was deleted during this phase. GitHub open pull requests were **zero**. The only workflow triggers development pushes to `main` and PRs; current deployments identify commits/Worker versions, not these local branch names. No additional worktree or known active integration dependency used an old branch.

Every branch below had **zero commits outside main**, and its tip was also reachable from `legacy-paymongo-final` and readable from the independently restored backup. All 17 obsolete local branches were deleted using `git branch -d` only after those checks. The apparent “ahead 1” on the old operations-monitor tracking relationship was already incorporated in main; it was not unpublished unique work.

| Local branch | Preserved tip | Disposition |
| --- | --- | --- |
| `codex/close-continue-recovery` | `80deca5aa171e63fcfa31384d6410c760e9b7f6a` | Deleted; ancestor of baseline, in backup. |
| `codex/madetokeep-payments-phase2` | `a0411bc0202a0a7ba29806a29895a833f2d03c2a` | Deleted; ancestor of baseline, in backup. |
| `codex/refresh-receipt-sticker-previews` | `bb0795f0221dfea55f41e0d758025d618dd85011` | Deleted; ancestor of baseline, in backup. |
| `event-lifecycle-coordination` | `2f8c11ae231457629d9d9d0409abf752edbdeae8` | Deleted; ancestor of baseline, in backup. |
| `feat/customer-operator-ui-emoji-release` | `1caf1d6fb794a549b66e4ac8af834c62b9361dd3` | Deleted; ancestor of baseline, in backup. |
| `feat/operations-studio-monitor-v2` | `d7f5d19d7cb0f53bbbfc8b9882a89d82957226e4` | Deleted; ancestor of baseline, in backup. |
| `feat/operator-dashboard-v2` | `a54f2eaad807459c94686d755de23201b9607834` | Deleted; ancestor of baseline, in backup. |
| `feat/qr-gallery-receipt-styles` | `02f95455e262738ee14050e65824fbdf4c26514a` | Deleted; ancestor of baseline, in backup. |
| `feat/smooth-monochrome-receipt-previews` | `7ab80c82ca7ac437bf3781a95434d86c16593325` | Deleted; ancestor of baseline, in backup. |
| `feature/operator-experience-v3` | `6d5978b2295202ea795d7173cfe1469bc612a597` | Deleted; ancestor of baseline, in backup. |
| `feature/operator-v4-1-1-ux-freedom` | `77c90c7d137337ccf2aad4b51fb636af208b466b` | Deleted; ancestor of baseline, in backup. |
| `feature/operator-workspace-v4-1-management-gallery-export` | `70f728036a4cffe1eab2d8786473af4e37375717` | Deleted; ancestor of baseline, in backup. |
| `feature/operator-workspace-v4-portrait-first` | `69fa594f638d362a321dd2c303697725c8781c69` | Deleted; ancestor of baseline, in backup. |
| `fix/portrait-operator-finalization` | `412fcef936ec29b7b92fd111d3a99af4eba91fef` | Deleted; ancestor of baseline, in backup. |
| `fix/recovery-operation-regressions` | `8e53d09c2b7bc485b81dcfdd0c8a159ebd4d11ce` | Deleted; ancestor of baseline, in backup. |
| `gallery/editorial-instagram-release` | `ecf83d4a581cfd59455d9e2dd76171324ecd48d4` | Deleted; ancestor of baseline, in backup. |
| `regular-booth-reliability` | `4fdd3ab4a4104d8ebce5a8ad4571ca04f15a399f` | Deleted; ancestor of baseline, in backup. |

Retained: local `main`, `origin/main`, symbolic `origin/HEAD → origin/main`, permanent `legacy-paymongo-final`, and pre-existing auxiliary Git refs. No unresolved or unpreserved branch was removed. No extra historical tags were needed because all old branch work is already in the single legacy baseline.

### Pre-existing unpublished snapshot retained

`stash@{0}` / `refs/stash` is **`a73f20e827c4c40ff7352a8abaecad4b94fdd6b1`**, named `codex-step3-desktop-consolidation-safety-2026-10-12`, based on `934a76d350fb3e09b63941c8e6436f85ab9cd43a`. It contains 55 tracked-file differences plus 68 saved untracked files. A blob comparison identifies 59 snapshot path entries with historical bytes absent from main's reachable history, including source/tooling and image evidence. This is not proof of missing current features; newer implementations differ. It is nevertheless unpublished work/evidence and was **not applied, dropped or published**. Its commit/parents (including the untracked parent) are included in the verified all-ref bundle and original Git metadata; a private `stash-audit.json` inventories the paths. No additional owner action is needed merely to preserve it; inspect separately before any future stash removal.

The pre-existing `refs/codex/turn-diffs/.../base` is an auxiliary tree snapshot, not an active branch, and is likewise retained/backed up. Do not prune either auxiliary ref to obtain a cosmetically empty ref list.

## Verification boundary

Git recovery was exercised against the backup object database; database exports were actually parsed and restored. The bundle contains Git objects, not signing private keys, Keychain items, provider balances, customer Drive media, or the full iPad container. Sustainable signing, provider financial closure and portable device restoration remain distinct gates in [the readiness report](README.md).
