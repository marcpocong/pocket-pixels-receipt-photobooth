# Native UI CI follow-up — 30 October 2026

Production Gate run [40949968906](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40949968906)
completed with the production suite and backend passing. Native UI passed 25/28; the aggregate
iOS check correctly failed because native UI failed. No billing or build restriction caused it.

## Failure evidence and correction

All three failures were in EventOperationsUITests. The runner used Xcode 16.4 / SDK 18.5
with its available iOS 26.2 iPad simulator; local validation uses Xcode 27.1 and iOS 26.5/27.0.
The exact hosted environment is not installed locally. The original three tests passed in a
fresh local iOS 26.5 baseline run, so a deterministic local reproduction is not claimed.

- Portrait controls/sticker review: after tapping Receipt Studio Save, `visible()` selected the
  outgoing `receipt-studio-controls` scroll view while the asynchronous workspace flush was still
  dismissing the editor. Its later swipe failed because only `event-workspace-scroll` remained.
  `finishStudio()` now waits for the editor to disappear and the parent workspace to be hittable
  before resolving any parent controls. Save/Cancel/reopen paths using the same boundary share it.
- V2 zoom: the test immediately read `Zoom 100%` after a native pinch. It now waits for the pending
  receipt render to complete before pinching (the hosted recording shows Updating preview just
  before the original pinch). The synthesized event record also shows only ~28 points of final
  finger separation at scale 2; a wider scale-3 native gesture avoids marginal recognition across
  runtimes. The test then requires an existing preview with a published, non-default Zoom value before capturing the value used by all unchanged tab-stability assertions.
- Workspace draft: the immediate text read contained the prefix `Unfinished Works` instead of
  `Unfinished Workspace`. The hosted recording shows the complete text immediately afterward,
  confirming delayed observation rather than lost input. The test now waits for the complete exact
  value before checking durable saving/relaunch. It never retypes a suffix or accepts a partial value. If input really is lost,
  the test still fails.

The correction changes only the UI test helper/observations, not application behavior. It adds
condition-based synchronization with existing UI transitions. No arbitrary sleeps, test retries,
removed tests, relaxed comparisons, workflow bypass or shortened suite. The receipt renderer,
recovery, saved data, signing and bundle identifier are untouched. Carlo needs no runtime update
for a UI-test-only change; its installed production implementation remains the same.

## Validation

- Before correction: the three affected tests passed locally on iOS 26.5 (baseline evidence only).
- After correction: simulator build-for-testing passed.
- Focused affected/adjacent flows on iOS 26.5: **4 passed**, zero failures/skips.
- Complete native UI target on iOS 27.0: **28 passed**, zero failures/skips, with the
  synchronization corrections. The final wider pinch is additionally verified below after rebuild.
- Final wider native pinch/Undo/Redo/tabs/Save/Cancel flow after the final build: **passed on both
  iOS 26.5 and 27.0**, zero failures/skips. This is an additional run of the existing test, not a
  retry of a failed assertion. Both complete suite and focused checks retain all original assertions.
- Production and backend: already passed in the failed hosted run; no related source changed,
  so they were not redundantly rerun locally. The normal final main push still runs the complete
  unmodified hosted workflow.

Local result bundles: `/tmp/mtk-ci-before-fix.xcresult`, `/tmp/mtk-ci-fix-focused.xcresult`,
`/tmp/mtk-ci-fix-native-full.xcresult`, and the final `...-final-zoom26.xcresult` /
`...-final-zoom27.xcresult`. Build logs: `/tmp/mtk-ci-fix-build.log` and
`/tmp/mtk-ci-fix-final-build.log`.
Hosted native log and its original result artifact were inspected separately. Final hosted
validation is reported according to its actual status, never inferred from local success.
