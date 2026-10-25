# Operator Workspace V4.1.1 acceptance

Synthetic records only. Images are actual rendered SwiftUI/native controls, not design mockups. Native captures use the DEBUG-only isolated fixture; its screen picker is test navigation and is not added to the shipped operator workspace. No camera, live payment, production gallery upload, Photos transaction or printer output runs in that fixture.

The baseline folder contains the original grid/list, hidden event-deletion feedback and 50/250/500/1,000 archive/scroll measurements. Candidate `performance.json` and `scroll.json` use the same harness. See the [implementation and validation report](../../docs/operator-workspace-v4-1-1.md) for interpretation and limits.

`focused-c-summary.json` records 62 passing targeted cases. `compatibility-summary.json` records 11 native UI cases plus reduced-width rendering on iOS 26.5. `final-feedback-summary.json` records five final focused feedback/accessibility cases. The final ownership summary and generic-device Release compile result complete the local candidate validation. Full test results stay in `/tmp/PocketPixelsV411/` and the standard CI artifacts.

Reviewed screenshots cover all requested states: portrait grid; empty and populated selection; select all; safe-area bulk actions; deletion review/results; list; card and Gallery Actions menus; empty state; transient export success; saved event designs; management menu; deletion success and relaunch; retained historical removal; active/applied explanations; archive/restore; storage failure; landscape; accessibility and 600-point reduced width. Native animation settles before the final captures. The final photo-sheet error capture proves the result is visible within the modal.

Highlights:

- [Portrait gallery](screenshots/sessions-grid-portrait.png)
- [Several selected / bulk actions](screenshots/sessions-several-selected-bulk-bar.png)
- [Deletion review](screenshots/session-deletion-confirmation.png)
- [List](screenshots/sessions-list-portrait.png)
- [Gallery Actions](screenshots/sessions-gallery-actions-menu.png)
- [Successful event deletion](screenshots/event-deletion-success.png)
- [Deletion after relaunch](screenshots/event-deletion-after-relaunch.png)
- [Historical design removed / occurrence kept](screenshots/historical-design-removed-run-retained.png)
- [Active guest protection](screenshots/active-guest-transition-blocked.png)
- [Accessible landscape selection](screenshots/sessions-accessibility-landscape-selection.png)
- [Reduced-width accessible selection](screenshots/sessions-reduced-width-accessible-selection.png)
- [Photo-sheet export failure](screenshots/photo-sheet-export-error.png)

Signing and bundle identifiers remain unchanged. Release validation is an unsigned generic-device compile, not deployment to Carlo. PR and post-merge main CI URLs and exact delivery SHAs are recorded in the PR and final owner handoff, avoiding a new evidence-only CI run.
