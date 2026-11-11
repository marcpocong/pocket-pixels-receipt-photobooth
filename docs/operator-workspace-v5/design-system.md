# Operator Workspace V5 design system

The operator interface extends the existing Made to Keep palette. It uses Apple SwiftUI controls without dependencies. The design system is confined to authenticated operator surfaces; guest capture, photos, receipt pixels and service implementations keep their existing behavior.

## Tokens

`OperatorDesignSystem.swift` owns `OperatorPalette`, `OperatorStyle` and the shared components. The original palette values are preserved.

| Role | Token / treatment |
| --- | --- |
| Canvas | `canvas`: brand paper |
| Custom elevated cards and header | `surface`: brand ivory light |
| Grouped forms and lists | Native inset grouped surfaces over the brand paper canvas |
| Primary text | `ink` |
| Supporting text / unknown observation | `secondaryText` |
| Primary action / selected destination | `accent`: brand burgundy |
| Card edge | `border`: burgundy at 14% |
| Selected navigation surface | `selected`: burgundy at 8% |
| Verified evidence | `ready`: dark green |
| Actionable follow-up | `warning`: dark amber |
| Current critical failure | `danger`: dark red |

Unknown, last reported, stale and ordinary queued work use neutral presentation. Success color requires evidence for the specific statement. A printer transport state never proves paper output. Monitoring acceptance never proves Telegram delivery. Connectivity never proves a payment provider or public gallery works.

| Typography role | Dynamic SwiftUI text style |
| --- | --- |
| Workspace title | `.title`, medium serif |
| Editorial section heading | `.title3`, semibold serif |
| Card title | `.headline` |
| Operational text / controls | `.body`, native control styles |
| Supporting explanation | `.callout` |
| Metadata / evidence timestamps | `.footnote` |

Serif is reserved for editorial headings. Operational data uses the system font. Native navigation titles use inline presentation. Uppercase section transformation is disabled at operator screen boundaries. Existing artwork typography remains independent.

Spacing tokens are 8, 12, 16 and 24 points. Custom cards have 16-point padding, a 16-point radius and one subtle border, with no decorative shadow. Page margins and section gaps are 24 points. Native grouped sections retain the platform's common geometry. Content width is capped at 940 points for custom portrait pages. Prominent controls target 48 points; existing 44-point minimum controls remain accessible.

## Components and navigation

- `operatorScreen()` gives every screen the paper canvas, inset grouped list style, consistent section spacing, minimum row height, non-uppercase headers, burgundy tint, large controls, inline navigation, light navigation appearance and sheet canvas.
- `operatorCard()` is the shared custom card surface, also used by setup, artwork and sample studio containers and report metrics.
- `OperatorSectionHeading` provides editorial section hierarchy and supporting context.
- `OperatorNavigationCard` provides one existing destination with a title, explanatory text, semantic icon and accessible hint.
- `OperatorStatusLabel` presents status text and an icon; meaning does not depend on color.
- `OperatorStatePanel` presents empty, unavailable and informational states without adding actions or hiding existing retry buttons.
- `OperatorFeedbackBanner` retains persistent actionable errors and six-second success feedback.
- Native `ProgressView`, `Form`, `Picker`, `Toggle`, `TextField`, alerts and confirmation dialogs retain their Apple accessibility and keyboard behavior.

Primary actions use native bordered prominent buttons with burgundy tint. Secondary actions use bordered buttons. Destructive actions retain native destructive roles and their original confirmation contents. Disabled controls retain their original reason text and authorization rules. There are no decorative controls.

The five primary destinations remain Home, Booth, Sessions, Events and Reports. Their bottom navigation is outside scrolling content, respects the safe area, and marks the selected destination for VoiceOver. Existing landscape regression layouts remain supported. Portrait is enforced by the existing app delegate and iPad project configuration; neither setting changed. Nested destinations use the existing typed stack and a single native Back button. The persistent workspace header supplies Help, System and Return to Booth. At larger text sizes it can use a vertical fallback.

## Evidence and states

Home follows current event → follow-ups → system observations → event activity → quick access. Every current summary follow-up is shown with its existing recovery destination. Ordinary pending uploads are kept in the gallery overview, separate from operator incidents. Parked financial follow-ups remain separate from active guests. Shared printer controls remain available after the compact overview.

Camera observations explicitly name their foreground-session scope. Printer state is last reported and includes the paper-inspection limitation. Network path and gallery delivery are separate. Paid events show event-server check time without claiming provider availability. Monitoring shows no observation, accepted observation or stale observation and explicitly excludes Telegram delivery. A visible minute-based `TimelineView` updates freshness text only; it sends no request and creates no background service.

Metric values continue to come from the exact durable event-run journal. Missing or unreadable values remain unavailable. Session lists retain summary-only lazy loading, thumbnail caching, scope/filter behavior and deferred archive reads. Native keyboard avoidance and interactive dismissal stay intact.

Detailed Booth Health uses a separate `In progress` observation for ordinary gallery queues. Items explicitly flagged by the existing queue as needing attention remain review items, as do unreadable queue records. This read-only classification does not enter upload scheduling or admission policy. Receipt Studio uses its existing Receipt/Tools switch at accessibility text sizes instead of constraining controls beside the preview.

Waiting Galleries displays active byte-transfer telemetry separately from public verification work. Each saved row names its last recorded stage instead of borrowing a global scheduler phase. An unreadable saved queue is shown as unavailable in Home/System/Waiting Galleries rather than as a zero count. These are observational changes; scheduler ownership, retry behavior and concurrency are unchanged.
