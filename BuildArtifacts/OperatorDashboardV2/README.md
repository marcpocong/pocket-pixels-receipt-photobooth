# Operator Dashboard V2 rendered evidence

Actual SwiftUI views rendered by `OperatorDashboardV2Tests.testRenderedWorkspaceAndMajorScreensInBothOrientations`, using an iPad simulator and synthetic isolated event-run records. These are not design mockups or customer records.

The full test renders 27 poses: Home, Events, Reports, System; all four setup stages; Overview, Sessions, Sales; printer recovery, in portrait (834×1194 points) and landscape (1194×834 points), plus Home and setup at Accessibility 3 and 700×1024 points, and an archived report-scope restoration pose. Selected PNGs are included here; the complete set is attached to the XCTest result.

Reviewed for section navigation, visible scope, four Home metrics, empty/error/unavailable records, safe recovery wording, readable contrast, persistent bottom setup actions, and large-text wrapping. Content below the viewport remains vertically scrollable. Readiness is deliberately unverified in the simulator. No test claims physical camera, paper output, authentication, or production connectivity success.
