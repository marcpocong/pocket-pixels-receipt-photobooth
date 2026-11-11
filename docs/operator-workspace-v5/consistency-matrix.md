# Screen consistency and preservation matrix

See [the baseline inventory](screen-inventory.md) for the source-level route graph, including inline links, sheet presentations and debug-only tools. Every row here was inspected for navigation, typography, semantic status, loading/error/empty behavior, and existing actions. All are authenticated operator destinations; action-level checks remain in their original owners.

“Shared” means the screen has an explicit `operatorScreen()` boundary or is a component within such a screen. Custom card implementations additionally use `operatorCard()`. Native alerts, pickers, system media selection and share/export sheets retain their standard platform presentation. Representative visual evidence is listed in the release report; inspection is not a claim that every possible runtime state was photographed.

| Screen / nested destination | Entry and purpose | V5 integration | Preserved behavior / state handling |
| --- | --- | --- | --- |
| Home | Home tab; daily overview | Shared shell, section headings, all follow-up cards, separate evidence cards | CurrentEventCard lifecycle/admission; current recovery destinations; unavailable metrics |
| Booth | Booth tab; Regular defaults | Shared form, next-guest intro, save bar | Staged defaults, format/copy validation, draft persistence, next guest scope |
| Receipt & Footer | Booth → footer | Shared form and full screen studio | Existing Save Defaults, preview, device inheritance |
| Regular Booth Preview | Footer → preview | Shared scroll screen | Existing receipt renderer; no automatic send |
| Sessions browser | Sessions tab / recovery links | Shared intro, search/filter controls, state panels | Lazy summaries/thumbnails, scopes, search, selection, corrupt/empty states |
| Session filter sheet | Sessions → Filters | Shared native form | Original filters and uncertainty explanations |
| Archived session detail | Sessions → original record | Shared detail chrome and canvas | Original archive, guarded reprints, copy selection, gallery evidence, exports |
| Original photo detail | Session → photo | Shared sheet | Deferred original loading, thumbnail limitations, export permissions |
| Original receipt / zoom | Session → receipt | Shared sheet around original pixels | Fit-first preview, zoom and original receipt integrity |
| Session deletion review | Sessions → manage | Shared review sheet | Existing explicit deletion eligibility, confirmations and retained financial records |
| Events | Events tab | Shared form, events/designs intro | Current event, saved designs vs runs, remove/archive/restore and durable feedback |
| Manage Event / Run | Events → actions | Shared sheet | Original removal review and scoped lifecycle safeguards |
| Rename Event | Events → rename | Shared form | Save/Cancel, validation and errors |
| New Event / Customize | Events → new setup | Shared screen and setup cards | Existing staged setup and Review & Start authorization |
| Use Previous Event | Events → previous | Shared setup and chooser | Previous designs remain separate from runs; selection does not activate |
| Saved Event Setup | Events → saved design | Shared setup child | Exact saved identity, draft restoration, no accidental application |
| Edit Live Event | Home/Events → edit | Shared setup/cards | Original live edit boundary, admitted guests keep snapshots |
| Event Setup / Charging | Existing typed routes | Shared setup/cards and save/review bar | Setup progress, operation errors and existing server revision checks |
| Previous design picker | Setup → previous design | Shared list sheet | Selection/cancellation; original draft identity |
| Review & Start / discard dialogs | Setup → review | Shared sheet / native confirmation | Existing explicit review, start and discard actions |
| Saved Drafts | Events → saved drafts | Shared list | Unreadable drafts retained; existing discard authorization |
| Review Draft | Saved Drafts → record | Shared review | Scoped draft changes, validation and retry |
| Edit Draft Design | Draft → edit | Shared editor | Per-design staged persistence |
| Branding & Design | Setup/Booth → branding | Shared list/form | Immediate device-default semantics and load-issue replacement flow |
| Guest Preview | Branding → preview | Shared surrounding screen | Actual guest preview is preserved |
| Receipt Studio | Branding/footer → customize | Shared chrome and controls | Original preview, typography, footer/artwork values, staged Save/Cancel |
| Header editor / receipt preview | Studio → header | Shared form and preview screen | Original artwork import, crop and receipt composition |
| Artwork editor / receipt preview | Studio → artwork | Shared chrome and custom cards | Original artwork transform, export and preview pixels |
| Typography / receipt panels | Studio controls | Shared containing editor | Existing font/layout choices and native selectors |
| Sticker Studio | Branding → stickers | Shared list | Existing catalog, operator preview and settings |
| Sticker library / custom sticker | Sticker Studio → library | Shared list and sheets | Original import/export/deletion behavior and errors |
| Advanced sticker settings | Sticker Studio → Advanced | Shared form | Existing supported controls |
| Sticker preview / Emoji print preview | Sticker Studio → preview | Shared chrome | Existing preview-only render and guarded printing |
| Sample Print Studio | Printer/Branding → samples | Shared screen and numbered cards | Operator permissions, photo slots, no automatic print, explicit unavailable reason |
| Sample photo chooser | Sample Studio → photo slot | Shared sheet | Original chooser, cancellation, staged photos |
| Reports Overview | Reports tab | Shared grouped list, editorial intro and metric cards | Exact run scope, journal errors remain unavailable |
| Reports Sessions | Reports section picker | Shared controls/list | Deduplication, lazy archived details, current filters |
| Reports Printing | Reports section picker | Shared metrics/list | Transport counts distinguished from paper output; reprints separate |
| Reports Galleries | Reports section picker | Shared metrics/list | Public verification distinct from upload |
| Reports Sales | Reports section picker | Shared form/list | Authoritative financial categories and read failures |
| Event History | Reports/Events → history | Shared reporting screen | Durable runs, removed/archived history and incomplete earlier activity |
| Saved Events / library | Events → manage saved | Shared reporting screen | Designs vs actual runs; restore/archive behavior |
| Earlier session attribution | History → review earlier | Shared review sheet | Explicit attribution, original records unchanged, no invented sales |
| Whole event sales / maintenance | Reports → server event | Shared server detail | Original binding, server totals, closure authorization |
| System & equipment | Header gear | Shared intro, separated network/gallery evidence | Original device routes; observations do not grant admission |
| Printer Setup | System → printer | Shared custom card and chrome | Transport selection, reconnect, guarded explicit test preview |
| Advanced printer / transport settings | Printer/Advanced → transport | Shared enclosing screen/card | Original Bluetooth/Wi-Fi controls and existing blocking explanations |
| Bluetooth diagnostics | Advanced printer → diagnostics | Shared screen | Existing explicit diagnostics, no automatic test receipt |
| Camera Check | System → camera | Shared screen | Existing camera ownership/preflight/active guest gates |
| Booth Check | System/Home → check | Shared screen | Original explicit checks, last evidence, no new mandatory diagnostic |
| Help & Recovery | Header lifepreserver | Shared list | Print Recovery, Close Session & Continue, retained history and existing instructions |
| Interrupted Receipt | Recovery → original receipt | Shared archived child | Original receipt lookup; no regenerated or automatic resend |
| Retained Sessions / retained detail | Recovery → retained | Shared list/detail | Original checkpoint/photos, missing and unreadable record guidance |
| Payment Maintenance | System/Recovery → payments | Shared form/list | Pairing, connection protections, original payment verification boundaries |
| Checkout details / manage / archived | Payment recovery → record | Shared sheets/list | Active vs parked vs resolved distinctions, no settlement through closure |
| Checkout deletion review | Checkout management → review | Shared review sheet | Existing eligibility, protected records and explicit confirmation |
| Waiting Galleries | Home/System → waiting | Shared list, neutral empty panel | Normal queued progress, explicit retry joins existing scheduler |
| Gallery Setup | System → gallery | Shared form | Keychain credentials, local retention, original backend check and privacy |
| Monitoring V3 | System → monitoring | Shared form | Original credential storage, explicit send/test, no delivery claims |
| Storage | System → storage | Shared list | Existing diagnostic readouts and safe archive/recovery guidance |
| Print History | System/Recovery → history | Shared list | Evidence only; unchanged uncertainty, no new operational gate |
| Advanced | System → Advanced | Shared grouped list | Existing maintenance, safe diagnostic export and debug-only tools |
| Gallery backend override | Advanced → backend | Shared form | Existing validated HTTPS override/default actions |
| Change Passcode | System → access | Shared form | Existing authentication, Keychain and passcode validation |
| Hardware Qualification | Advanced → qualification | Shared screen | Existing simulated default, explicit hardware approval and report history |
| Qualification approval / prompt / report | Qualification → run | Shared sheets/detail | Existing approval boundaries, cancellation, recorded observations |
| Endurance / Chaos Harness (Debug) | Advanced developer tools | Shared enclosing screen | Existing debug-only controls and explicit operations |
| Printer test / sample previews (Debug) | Advanced developer tools | Shared screens | Existing explicit-send boundaries |
| Camera development tools (Debug) | Advanced developer tools | Shared screen | Existing camera controls |
| Gallery development tools (Debug) | Advanced developer tools | Shared forms/previews | Existing explicit test operations |
| Booth development tools (Debug) | Advanced developer tools | Operator shell; actual guest view preserved | Existing guest model and debug behavior unchanged |
| Authentication / PIN | Welcome → operator | Existing brand screen retained | Original authorization boundary, private input and session permit |

## Uniform interaction/state review

Page titles and section headings are visible text, and custom headings carry header traits. Shared action icons are hidden from redundant VoiceOver reading; cards retain labels and destination hints. Navigation uses native Back, existing typed paths and saved section paths. Primary tabs stay visible while primary content scrolls. Nested editors keep their original cancellation and draft handling. Large text switches custom grids to one column; native forms wrap and retain keyboard avoidance.

Existing loading indicators remain attached to their original async owners. Errors keep original retry actions and original files. Empty session/gallery states explain where future records appear. Destructive dialogs retain their original roles and full wording. Success/error feedback retains its original dismissal lifetime. No component creates a guest gate, print retry, financial action or backend deployment.
