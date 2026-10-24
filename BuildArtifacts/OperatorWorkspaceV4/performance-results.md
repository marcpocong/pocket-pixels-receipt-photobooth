# Measured archive browser performance

Baseline: Xcode 27.1 / iOS 26.5 simulator, original eager browser with isolated synthetic archives. Final table: steady focused iOS 27.0 simulator run after the native scroll restoration fix, on the same Mac; OS/runtime differences and ordinary filesystem caching are limitations. `performance-ios26.json` also records the optimized supporting iOS 26.5 run. No physical-device FPS improvement is claimed.

| Sessions | Baseline metadata ms | Final metadata ms | First preview after metadata ms | Baseline filter ms | Final filter ms | Decoded cache MiB | Final process footprint MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 50 | 113.66 | 12.75 | 28.79 | 0.123 | 0.161 | 9.38 | 33.27 |
| 250 | 518.55 | 18.46 | 1.59 | 0.639 | 0.836 | 12.00 | 33.81 |
| 500 | 976.60 | 36.86 | 1.18 | 1.219 | 1.887 | 12.00 | 35.69 |
| 1000 | 1949.76 | 76.82 | 1.20 | 2.401 | 3.755 | 12.00 | 35.72 |

Filtering remains a few milliseconds at 1,000 sessions. This single-query microbenchmark is slightly slower than baseline; the benefit of the presentation cache is avoiding repeated filtering/grouping in SwiftUI row/body evaluations. It is not reported as a measured filter speedup. Process footprint includes the XCTest host, fixtures and framework caches; supporting full-suite captures also include prior tests. Baseline footprint was not recorded. Cache eviction is proven independently by byte/count assertions, repeated-request hits, concurrent readers and memory-warning tests.

The comparable optimized iOS 26.5 supporting run measured metadata at 6.06 / 17.79 / 36.36 / 67.03 ms for 50 / 250 / 500 / 1,000 archives. This is the direct same-runtime counterpart to the baseline.

Four-second programmatic scroll: see `scroll-final.json` for display-link callback intervals. This is a callback-pacing observation, not an Instruments animation-hitch or physical-FPS result. Return/rotation assertions retain selection and filters; the final source additionally refreshes metadata when re-entering a retained Sessions root without resetting those values.

A separate **16.63-second Time Profiler** simulator capture collected **7,013 samples**. **201 samples contained ImageIO thumbnail creation; none were on the main thread.** Ten potential hangs were recorded: nine 316–455 ms intervals were dominated by screenshot capture/PNG/XCTest attachment work, and one 573 ms interval by teardown of temporary synthetic fixtures. These harness costs are reported rather than counted as normal scrolling. `instruments-summary.json` records their stack correlations. The capture also reported one table without a known input source; its Time Profiler and potential-hangs tables exported successfully. The trace is statistical evidence, not proof that every possible frame is hitch-free. The raw trace ZIP can be opened in Instruments after extraction.

The acceptance check also records actual return geometry: [measured offsets](scroll-restoration.txt), [before-fix failed test](scroll-restoration-before-fix.json), [steady passing restoration run](scroll-restoration-verified-ios27.json), and [recreated-view section re-entry](section-reentry-verified-ios26.json). The pixel-offset tolerance was retained; both final return paths measured 5,736 → 5,736 points.
