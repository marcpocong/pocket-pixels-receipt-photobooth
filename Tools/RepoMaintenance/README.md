# Local repository cleanup

Run from the repository root with Python 3.9 or newer:

```sh
python3 Tools/RepoMaintenance/clean-local.py
python3 Tools/RepoMaintenance/clean-local.py --apply
```

The first command previews logical bytes and file count. The second removes only ignored
outputs in the explicit build/test/temp directories, ignored raw `BuildArtifacts` files,
and known Wrangler packages/account caches. It refuses to delete tracked or non-ignored
new work. It leaves Git history, source, secrets and Wrangler local database state alone.
It never contacts Cloudflare or an iPad. Close active builds/tests before running it.

Save private snapshots outside the repository first; explicitly stage any new curated
evidence that needs to survive cleanup. Ignored files are otherwise disposable.

`--dependencies` additionally removes `Backend/PaymentsWorker/node_modules`.
Restore pinned backend dependencies with `npm ci` inside `Backend/PaymentsWorker`.

See [the repository maintenance policy](../../docs/repository-maintenance.md).

Run the deletion-guard checks in disposable Git repositories:

```sh
python3 Tools/RepoMaintenance/test-clean-local.py
```
