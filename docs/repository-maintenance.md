# Local repository maintenance

The 11 November 2026 cleanup removed accumulated generated outputs and grouped the older
root reports under `docs/`. Source, tests, assets, the Xcode project/signing settings,
Git history, tracked validation evidence and the pending D1 index repair files were preserved.

## Where things belong

| Content | Location |
| --- | --- |
| iPad app, tests and Xcode project | `PocketPixelsBooth/`, test target folders and `.xcodeproj` |
| Worker/Apps Script source, migrations and tests | `Backend/` |
| Maintained development and operational documentation | `docs/` and its index |
| Earlier release/implementation and phase reports | `docs/archive/` |
| Feature and hardware validation checklists | `docs/validation/` |
| Reviewed screenshots, rasters and compact result summaries | `BuildArtifacts/` |
| Repeatable development tools and asset sources | `Tools/` |
| Disposable Xcode products, raw test results and scratch files | Ignored `DerivedData/`, `TestResults/`, `build/`, `.tmp/` |
| Private device snapshots and database backups | Outside the repository, in restricted private storage |

The root `PocketPixelsTheme.swift` belongs to the Xcode target and stays in place.
Historical documentation may reference raw local bundles that have since been removed;
the cleanup preserves committed evidence and does not rewrite those historical results.

## Keeping local output small

Preview and apply cleanup with:

```sh
python3 Tools/RepoMaintenance/clean-local.py
python3 Tools/RepoMaintenance/clean-local.py --apply
```

Close builds/tests first. Preserve private snapshots elsewhere and explicitly stage curated
evidence before cleanup. The tool aborts if a selected output directory contains tracked or
non-ignored work. It does not perform cloud operations or touch installed iPad data.
`--dependencies` can also remove the backend install; `npm ci` restores it from its lockfile.

Use `git gc --no-prune` for ordinary local packing without deleting unreferenced objects.
Do not rewrite history or purge Git recovery records merely to shrink the checkout.
Do not place raw `.xcresult` bundles, full logs, device inventories or database exports in
Git. Existing tracked evidence remains tracked despite broad raw-output ignore rules.

## Private cleanup records

Before deletion, source/worktree hashes and the existing patch were recorded privately.
Small untracked device records, summaries, preference snapshots and earlier scratch scripts
were moved to restricted storage at
`~/Library/Application Support/PocketPixelsBooth/RepoMaintenance/20261110T191518Z/`.
The production database backup from the D1 repair remains separately under the application's
private `Backups/CloudflareD1/` directory. Neither location is cleaned by the repository tool.

## 11 November cleanup results

- Initial checkout footprint: approximately **7.8 GiB** (`du`, including `.git` and dependencies).
- Final checkout footprint: approximately **947 MiB**, about **88% smaller**, including
  preserved Git history, 203 MiB of curated evidence and the installed backend tools.
- Removed **69,235 ignored generated files**, totaling **6.63 GiB logical size**: old Xcode
  products, raw result bundles, logs, repeated captures/renders and temporary packages.
- Preserved 338 small private records/scratch scripts outside the repository (about 41 MiB
  including the maintenance manifests and logs). These were moved, not silently discarded.
- Moved 13 historical reports/checklists from the root into the archive/validation folders;
  updated their relative links and added navigation indexes. Root app source stayed in place.
- Removed two stale worktree registrations whose directories no longer existed, packed Git
  objects without pruning recovery objects, and removed 22.38 MiB of month-old abandoned
  temporary pack files. No branch, commit history or installed backend dependency was deleted.
- Hash verification found no missing original source/evidence/work files and no unexpected
  changes. The existing gallery-performance notes and D1 repair files remained byte-for-byte
  identical to the pre-cleanup snapshot.
- All 77 checked local documentation links resolve. All five cleanup safety checks and
  six D1 migration tests passed; backend syntax checks and Git connectivity checks passed.
- A fresh generic iPad simulator app build completed with **BUILD SUCCEEDED**. It used an
  external temporary DerivedData directory, which was removed after the build. Existing
  compiler warnings remain in unchanged app sources; no app signing settings were changed.

The cleanup tool defaults to a preview and is not scheduled to delete anything automatically.
