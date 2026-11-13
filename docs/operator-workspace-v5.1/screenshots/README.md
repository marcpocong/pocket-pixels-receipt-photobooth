# Prepare Event portrait evidence

Synthetic events on the fourth-generation 11-inch iPad Pro simulator, iOS 26.5; 834 × 1194 points. Captures were visually reviewed for source labels, wrapping, controls, margins, native Back navigation and the persistent Continue action. [manifest.json](manifest.json) records dimensions and SHA-256 hashes. No customer media is included.

| Capture | Evidence |
| --- | --- |
| [Saved overview](01-saved-overview.png) | Default saved source, unsaved-change notice, configuration and shortcuts |
| [Staged overview](02-staged-overview.png) | Explicit staged source and guest welcome change |
| [Preparation tools](03-preparation-tools.png) | Printer, Booth Check and Gallery shortcuts; unknown observation is truthful |
| [Accessibility overview](04-accessibility-overview.png) | Larger text, adaptive rows and persistent Continue |
| [Accessibility guest preview](05-accessibility-guest-preview.png) | Reused static guest preview and scrollable tools |
| [Contextual receipt editor](06-contextual-receipt-editor.png) | Existing Receipt Studio opened for the selected design |
| [Existing review](07-existing-review.png) | Existing Review Setup sheet reached through Continue; activation was not tapped |
| [Accessibility editor focus](09-accessibility-editor-focus.png) | Correct staged event in the existing editor, focused name and reachable Done Editing |

The UI test asserts keyboard presence, field/Done Editing hittability and dismissal. The screen capture omits the keyboard surface, so this image is focus evidence rather than visual proof of every docked/floating keyboard layout. Physical VoiceOver and keyboard acceptance remain device checks. The uncurated inline receipt-preview capture remains in the local test artifact; the full receipt editor is the curated receipt image.
