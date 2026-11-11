# Portrait verification gallery

These captures use the 11-inch iPad Pro, fourth generation, simulator at 834 × 1194 points. UI-test captures show the real workspace shell; hosted captures isolate the corresponding production views. Data is synthetic. The receipt preview is the original synthetic archive, not regenerated customer artwork.

| Surface | Evidence |
| --- | --- |
| Home | [Home](home.png) |
| Booth defaults | [Booth](booth.png) |
| Sessions | [Sessions](sessions.png) |
| Events | [Events](events.png) |
| Reports | [Reports](reports.png) |
| System | [System](system.png) |
| Help & Recovery | [Recovery](recovery.png) |
| Waiting Galleries | [Waiting Galleries](waiting-galleries.png) |
| Gallery settings form | [Gallery Setup](gallery-settings.png) |
| Receipt & Footer form | [Receipt settings](settings-form.png) |
| Archived receipt detail | [Session detail](session-detail.png) |
| Sample Print Studio | [Sample Studio](sample-studio.png) |
| Receipt Studio | [Receipt Studio](receipt-studio.png) |
| Accessibility text | [Home](home-accessibility.png), [Receipt Studio](receipt-studio-accessibility.png) |
| Keyboard with accessibility text | [Sessions and keyboard](sessions-keyboard-accessibility.png) |
| Long event name with accessibility text | [Long event](long-event-name.png) |
| Simultaneous follow-ups | [All current issues](simultaneous-follow-ups.png) |

Reviewed for portrait reading order, common canvas and tint, native Back navigation, persistent primary tabs, wrapping text, visible state explanations and preserved receipt pixels. The keyboard capture demonstrates safe-area adjustment. Screenshot artifacts are visual review baselines; the tests additionally assert navigation reachability and behavior rather than depending on OS-specific pixel equality.

Physical camera, Bluetooth, paper output/cutting/recovery and real payment-provider acceptance are separate from these captures. Manual VoiceOver use on Carlo remains a physical acceptance check; accessibility grouping, labels, large text and touch reachability are covered in the implementation and simulator checks.
