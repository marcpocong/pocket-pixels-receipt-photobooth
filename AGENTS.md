This is an iPad-only SwiftUI receipt photobooth.

- Preserve bundle ID and signing.
- Prefer Apple frameworks.
- Do not add dependencies without explicit approval.
- Build after every meaningful change.
- Keep printer, camera, receipt rendering, and cloud services separated.
- Print history is evidence, not an operation lock. Use current receipt/session recovery and unfinished sends for operational gates; keep report sync/review separate. Cover acknowledgment → relaunch → next guest/event in regression tests when changing recovery behavior. Never automatically resend a copy that may have printed.
