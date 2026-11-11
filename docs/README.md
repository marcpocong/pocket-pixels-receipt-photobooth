# Development documentation

## Current handoff

- [12 November Operator Workspace V5 release](operator-workspace-v5/release-report.md): unified portrait UI, route inventory, visual evidence, local validation and Carlo installation.

- [27 October 2026 handoff](development-handoff-2026-10-27.md): accepted printer limitation, final printing/digital-image separation, empty sample previews, prepaid copy authorization, CI root causes and verification.
- [Receipt printing investigation and implementation](receipt-footer-first-printing.md): chronological measurements, code changes, retired paper-return probe and physical findings.
- [Portrait delivery record](../BuildArtifacts/PortraitWorkspace/delivery-report.md) and [curated evidence index](../BuildArtifacts/PortraitWorkspace/README.md).
- [Repository rules](../AGENTS.md) and [project overview](../README.md).
- [Repository organization and cleanup](repository-maintenance.md), [historical reports](archive/README.md)
  and [validation checklists](validation/README.md).

## Operator workspace and event lifecycle

- [Operator Workspace V5 design system and evidence](operator-workspace-v5/README.md)

- [Portrait event workspace](portrait-event-workspace.md)
- [Operator workspace V4.1.1](operator-workspace-v4-1-1.md)
- [Operator workspace V4.1](operator-workspace-v4-1.md)
- [Regular Booth upgrade](regular-booth-upgrade-2026-10-17.md)
- [Event lifecycle coordination](event-lifecycle-coordination-2026-10-17.md)
- [Event integrity and recovery](event-integrity-recovery-2026-10-17.md)
- [Event setup and checkout management](event-workspace-and-checkout-management.md)

## Payments, recovery and reporting

- [11 November D1 read alert investigation and live fix](d1-idle-read-audit-2026-11-11.md)
- [Payment operations](payment-operations.md)
- [Payment Phase 2 architecture](payments-phase2-architecture.md)
- [Payment Phase 4 audit](payments-phase4-audit.md)
- [Close/continue recovery](close-continue-recovery.md)
- [Recovery friction prevention](recovery-friction-prevention.md)
- [Event runs and reports](event-runs-and-reports-2026-10-16.md)
- [Payments Worker setup](../Backend/PaymentsWorker/README.md)
- [Monitoring V3 architecture and classification](monitoring-v3/ENGINEERING.md)
- [Monitoring V3 manual rollout and rollback](monitoring-v3/ROLLOUT.md)
- [Monitoring V3 validation](monitoring-v3/VALIDATION.md)
- [Monitoring Worker setup](../Backend/MonitoringWorker/README.md)

## Receipt and gallery delivery

- [11 November gallery delivery reliability, transport and rollout](gallery-delivery-reliability-2026-11-11.md)
- [Monochrome receipt behavior](monochrome-receipt-release.md)
- [Receipt/footer gallery styles](qr-gallery-receipt-styles-release.md)
- [Gallery upload performance](gallery-upload-speed-release.md)
- [Cloudflare gallery proxy](../Backend/CloudflareGalleryProxy/README.md)
- [Apps Script setup](../Backend/GoogleAppsScript/SETUP.md)

Earlier release reports are historical evidence. Their pending CI or installation statements describe that earlier checkpoint; use the current handoff and the exact commit's GitHub Actions run for current status.
