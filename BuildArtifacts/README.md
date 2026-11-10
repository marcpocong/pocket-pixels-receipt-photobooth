# Curated validation evidence

This directory keeps reviewed screenshots, receipt rasters, compact test summaries and
delivery reports. Existing tracked files are preserved. Raw Xcode result bundles, full
logs, duplicate exports and machine/device inventories are disposable local outputs;
they were cleaned on 11 November 2026. Historical reports can still mention those former
local paths. Their committed summaries and curated images remain available here.

Start with:

- [Portrait workspace and physical printer findings](PortraitWorkspace/README.md)
- [Close/continue recovery](CloseContinueRecovery/README.md)
- [Gallery performance](GalleryPerformance/README.md)
- [Gallery upload speed](GalleryUploadSpeed/README.md)
- [Gallery receipt styles](GalleryReceiptStyles/README.md)
- [Operator workspace V4.1.1](OperatorWorkspaceV4.1.1/README.md)
- [Operator workspace V4.1](OperatorWorkspaceV4.1/README.md)
- [Operator workspace V4](OperatorWorkspaceV4/README.md)
- [Operator dashboard V2](OperatorDashboardV2/README.md)
- [Operator experience V3](OperatorExperienceV3/README.md)
- [Event operations](EventOperations/README.md)

Generate new raw results under ignored `TestResults/` or an external temporary directory.
For a lasting record, extract a short summary and selected images, inspect them for private
data, and explicitly add just those files with `git add -f`. Keep private device snapshots
and database exports outside the repository. See [repository maintenance](../docs/repository-maintenance.md).
