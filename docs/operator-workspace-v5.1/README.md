# Prepare Event — Operator Workspace V5.1

Events → saved event → Prepare Event is a read-only preparation hub keyed by `SavedEventDesign.id`. The saved row keeps an independent Edit shortcut. Preparing a reusable design does not create or switch a historical event occurrence.

`EventPreparationPresentation` projects the library, workspace snapshot and existing run observations without constructing a setup coordinator. Saved content is the default on every visit. Selecting Staged draft is local UI state; the page labels its configuration and receipt provenance. Payment-only drafts retain a **Saved design preview** label. Library-owned bindings and tombstones override stale draft metadata. Policies without a local snapshot are described as inherited or server-managed, rather than reconstructed from defaults. Server status is explicitly unchecked; opening the page performs no payment request.

The screen reuses V5 operator tokens, native scrolling, adaptive summary rows and a persistent Continue action. Receipt and guest previews expand on demand. The hub suppresses receipt export and print controls, including in the expanded inspector; other existing preview consumers retain their controls. Printer observations are labeled as last recorded, with a timestamp when available. Opening the hub does not run checks, print, schedule uploads or impose a checklist.

| Action | Reused system |
| --- | --- |
| Edit / Continue | `OperatorSavedEventSetupView` → `SessionSetupView` → existing `SessionSetupReviewView` |
| Active event edits | Existing live-edit setup; applies allowed changes to future sessions |
| Customize Receipt & Branding | Same contextual setup coordinator → `EventDesignEditorView` / `ReceiptStudioView` |
| Receipt / guest preview | `EventReceiptComposerPreview` / `CustomerExperiencePreviewView` |
| Printer / Booth Check | Existing `.printer` / `.boothCheck` destinations |
| Gallery / Waiting Galleries | Existing `.gallery` / `.waitingGalleries` destinations |
| Unavailable / archived / removed | Existing event library and recovery destinations |

Tool links push onto the current navigation stack, retaining the preparation route on Back and during workspace restoration. No save operation lives in this hub. Archived designs remain editable; existing setup prevents starting them until restored. Unreadable originals are unavailable, while write failures leave readable designs accessible for retry. The saved-event editor waits until the requested identity is loaded before displaying setup or presenting Receipt Studio; unavailable designs never fall through to blank setup. Existing activation, admission, frozen guest configuration, print recovery, gallery scheduling and event occurrence ownership are unchanged.

Validation and limitations are recorded in [release-report.md](release-report.md). Synthetic portrait evidence is listed in [screenshots/README.md](screenshots/README.md).

For UI keyboard validation, disable the simulator’s connected hardware keyboard (`defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool NO`) and restart the isolated simulator before running `EventPreparationUITests`. Restore the previous preference after validation. The tests use only simulator fixtures and never tap activation, test print or payment actions.
