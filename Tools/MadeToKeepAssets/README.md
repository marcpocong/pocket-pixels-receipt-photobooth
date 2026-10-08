# Made to Keep decorative assets

`GenerateMadeToKeepAssets.swift` regenerates the decorative bitmaps in `PocketPixelsBooth/Assets.xcassets`
from the Made to Keep reference design (1048 × 1501 PNG):

```sh
swiftc -O Tools/MadeToKeepAssets/GenerateMadeToKeepAssets.swift -o /tmp/mtk-gen
/tmp/mtk-gen /path/to/made-to-keep-reference.png /tmp/mtk-out
```

Outputs:

| File | Use |
| --- | --- |
| `MadeToKeepWelcomeBackdrop.png` | Reference paper, perforated sheet, faded 2×2 collage and safety pin with **all text and the CTA removed** (mask + diffusion inpaint). The welcome screen draws every word and the button natively on top. |
| `MadeToKeepPaperTexture.png` | Procedural ivory paper (low-frequency tone, creases, grain) used behind every other guest screen and beside the poster in landscape. |
| `MadeToKeepAppIcon.png` | Copy into `AppIcon.appiconset/AppIcon.png`. |

The script is a developer tool only; it is not part of any app target.
