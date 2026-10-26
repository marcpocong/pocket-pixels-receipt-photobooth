# VOZY G80 top spacing investigation

Status: **accepted limitation; investigation closed at the owner's request**. The owner identifies the printer as **`80-VI 80.C-z04-AA`** and accepts a **16–17 mm** physical bottom gap despite zero programmed blank bottom rows. Digital margins are restored. In the owner-observed return-command diagnostic, **A did not cut; only B cut**. The approximately 23 mm bar-to-bar spacing is fixed artwork, not a margin measurement. This is a failed cut-and-return compatibility result, not proof that paper-saving behavior works. Its controls are retired from the sample screen; code and tests remain under `DEBUG` only. See [current implementation and physical result](../../docs/receipt-footer-first-printing.md) and the [final handoff](../../docs/development-handoff-2026-10-27.md). The earlier investigation record below is retained as history; no Windows utility or manufacturer follow-up is pending for this release.

## Verified software evidence

- Earlier compact-header change `fd45f91` reduced the masthead inset by 48 dots / 6 mm. Current source retains that correction; production feed/cut commands did not change with it or with the portrait workspace follow-up.
- Read-only inspection of Carlo confirmed default header topSpacing 8 dots and direct Bluetooth receipt printing. It did not reveal an app setting adding 20 mm before the raster.
- The initial focused regression passed; its final name is `SamplePrintStudioTests.testSamplePrintPipelineKeepsCompactTopMarginAndPrintsFooterFirstWithoutExtraFeed`. It covers all six formats × three footer styles through SamplePrintComposer.prepare and the final PrintJobEnvelope.
- Every tested standard sample starts ink at 34 dots / 4.25 mm. The envelope contains only ESC @ and the eight-byte raster header before the frozen raster data; no leading line feed or added blank raster rows occur.
- These printer regressions were developed after Gate #146 and are included in the final handoff's source and CI suite.

## Physical evidence limits

The owner reports approximately 20 mm above Made to Keep in Sample Print Studio across formats, with smaller gaps on the same printer previously. The owner could not locate the suggested diagnostic screen, so the reply “20 mm” is not treated as evidence that a text-only test ran. The actual Thermal Raster PNG and matching paper photograph remain unavailable.

A Mac-only CoreBluetooth probe found the G80. The follow-up connection timed out before characteristic discovery and before any SEND INTENT. Zero print payloads were sent by the Mac. Experimental command tests stopped when the owner requested software-only work. The later request authorized investigating printer settings, but no setting has been applied.

## Official utility inspection

Official source: https://www.vozyprinter.com/pages/downloads . VOZY links G80/P50 Mac and Windows drivers and Printer Setting Tools V1.0.8 for Windows.

Downloaded utility SHA-256: `8993f182f30f6acd78caf0be7b37f4b3065f2c75f7024ce37e71baf1ce818c17`.

The executable was inspected as data; it was not run on the Mac. Its advanced dialog resource contains “票据顶部空白去除” (remove blank space at the top of a receipt), combo control 1169 and Set control 1170. However, its Set handler at 0x403070 only updates dialog data and has no direct outbound write, unlike neighboring compression setters. Thus the resource label alone does not establish a working supported G80 setting. No inferred private command was sent.

The Windows UI uses the Ticket Printer Set tab; its Advanced button is at the bottom-left, left of Check USB Port. Actual owner-visible UI and option availability remain to be confirmed.

The Mac DMG was mounted read-only, expanded, inspected and ejected without installing a driver. Its POS-80 descriptor exposes per-job cut and post-job feed choices. Such Mac print-driver preferences do not affect the iPad app’s direct Bluetooth payloads. No firmware update, factory reset, Bluetooth rename, network change, or persistent configuration write occurred.

## Historical Windows handoff (closed without a configuration change)

Owner has a Windows computer and could not initially find the control. Exact verified English path is Ticket Printer Set tab → Advanced at bottom-left, immediately left of Check USB Port. The actual Chinese translation in this utility is 其他功能设置 (not 高级). A screenshot of the owner's Windows utility was requested; the assistant cannot see or operate that separate computer through the current Mac tools. Do not claim the setting was read from the printer merely because a dropdown shows a preselected value. No current setting value, supported write command, or successful readback has been established.
