# Operator Experience V3 screen review

These are captures of the app's **actual SwiftUI views hosted in an iPad simulator XCTest window**, using synthetic local event/session data. They are not physical iPad or printer tests. The XCTest result bundles also retain the complete screen attachments.

Reviewed at 834 × 1194 points (portrait), 1194 × 834 points (landscape), and 700 × 1024 points with accessibility text size 3. Screenshots are rendered at simulator scale. Scrollable content continues below the viewport; these captures do not imply every control fits without scrolling.

- [Home — portrait](home-portrait.png), [landscape](home-landscape.png): everyday actions appear before status cards.
- [Regular Booth Settings — portrait](regular-defaults-portrait.png), [landscape](regular-defaults-landscape.png): copy/format controls, readable format names and navigation-bar Save.
- [Printer Setup — portrait](printer-setup-portrait.png), [landscape](printer-setup-landscape.png): current status, reconnect, change printer, explicit manual test and Advanced.
- [Help & Recovery — portrait](printer-recovery-portrait.png), [landscape](printer-recovery-landscape.png): empty/current-action section separated from history.
- [Receipt & Branding](setup-3-portrait.png), [Review & Start](setup-4-landscape.png): staged event controls and preview.
- Large text: [Home](home-accessibility-portrait.png), [Regular Booth](regular-accessibility-portrait.png), [Printer](printer-accessibility-portrait.png).

The rendering suite also covers Events, Reports, System, all four event setup stages, device branding, Recent Sessions, retained sessions, report scopes and large-text event review. Physical fault states and connected hardware need the [owner acceptance checklist](../../docs/operator-experience-v3-ipad-checklist.md).

See the [implementation and validation report](../../docs/operator-experience-v3.md) for scope, navigation, safeguards, test results and remaining acceptance work.
