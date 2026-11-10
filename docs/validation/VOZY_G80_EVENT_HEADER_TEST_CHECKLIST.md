# VOZY G80 Event Header Validation

Use a production-equivalent iPad, the intended 80 mm paper, and the VOZY G80. Record the app build, iPadOS version, printer connection type, paper stock, date, and operator.

- Print the Pocket Pixels default header and confirm `EST. 2024` and the existing masthead remain unchanged.
- Import and print a normal PNG custom header.
- Import and print a transparent PNG; confirm transparent areas are white, not black.
- Import and print a JPEG/JPG custom header.
- Print a custom header with the Event Text Block on.
- Print the same header with the Event Text Block off; confirm no blank text area remains.
- Print with No Header; confirm only a small intentional top margin remains.
- Print a cropped, panned, and zoomed header and compare it with the full receipt preview.
- Print multiple copies and confirm every copy is identical and copy progress is correct.
- Run consecutive customer sessions using different event/header configurations; confirm each keeps its own header.
- Change the active event, then reprint an older session; confirm the archived receipt retains its original header.
- Inspect very dark artwork for excessive heat, drag, or large filled areas.
- Inspect fine typography and logo edges for legibility.
- Inspect feed length and cut behavior for each header mode.
- Run repeated BLE prints and confirm header processing does not change acknowledgement, recovery, or uncertain-output behavior.

Simulator image, layout, raster, and regression tests do **not** prove real thermal-paper quality. Do not mark physical VOZY G80 validation complete until these checks have been performed on hardware.
