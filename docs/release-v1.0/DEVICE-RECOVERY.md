# Booth backup and recovery

Use a private, encrypted location for each dated snapshot. The persistent app container covers saved designs, artwork, receipt templates, settings, archived sessions and run reports. When present, it also holds pending gallery media and transfer journals, payment records and receipt references, print outcomes, and recovery checkpoints. The snapshot has sensitive data. Keep it outside Git and shared folders.

## Capture before an update

1. Wait for physical printing to finish. Close admission and finish or park any current guest using the existing recovery screen. Quit the booth app on the unlocked, trusted iPad before copying.
2. Use Xcode's Devices and Simulators window or `xcrun devicectl device copy from` to copy `Documents`, `Library/Application Support`, and `Library/Preferences` from the app data container for `com.pocketpixels.PocketPixelsBooth`. Put the copied paths under `container/` in a new private backup directory. If `Documents` is absent or empty, record that in the capture inventory. Exclude caches and temporary files.
3. Seal the copy and verify it independently. A consistent snapshot requires the app to stay stopped during the copy. Store an encrypted second copy under owner control.

```sh
python3 Tools/BoothBackup/booth_backup.py seal /private/backup
python3 Tools/BoothBackup/booth_backup.py verify /private/backup
python3 Tools/BoothBackup/booth_backup.py restore-offline /private/backup /private/new-review-copy
```

The manifest checks paths, byte counts and SHA-256 for every captured file. The restore command uses a new local review directory. It performs no app launch, device writes, financial import, publication, or printing. Verify the source snapshot separately before any subsequent manual copy. Keep device identifiers, backup contents and private manifests out of release artifacts.

## Device replacement or failed update

- For a failed update, retain the existing container and capture a second snapshot before repair. Reinstall a currently signed compatible build in place using the original team and bundle identifier. Check configuration and saved records after launch.
- For replacement, retain the old snapshot as evidence. Use the same bundle identifier and compatible signing. Review and transfer saved designs, artwork, receipt settings and appropriate history with the replacement app stopped. Validate the restored design and settings offline before connecting the booth. Review event IDs and current admission settings before opening a session.
- Keep operational journals in the offline review copy until an operator compares them against the latest server state and actual printer output. An old print intent or an uncertain outcome cannot be replayed as a fresh copy. Match pending gallery transfer state to the original server session, identity and upload status. Use the existing application recovery controls for individual obligations. There is no bulk live journal restore.
- Re-pair device and operator credentials through the normal protected UI. Keychain items and vendor secrets are outside this backup, including device-only Keychain entries. Keep access and recovery credentials in the owner's approved credential store. Receipt images remain in private Drive. Local references point to the original service and checkout.
- Restore a D1 dump only to an isolated database for verification or analysis. Review and reconcile any required forward repair against current financial history. Keep the production database as the authority.

The recovery drill covers byte-level restoration and isolated review. Real device-to-device workflow activation requires an operator review of the source data. Phase 4 should verify this procedure against a richer snapshot containing synthetic pending work.
