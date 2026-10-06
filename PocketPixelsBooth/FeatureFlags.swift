import Foundation

/// Compile-time/internal gates for future experiments. Production behavior stays off by default.
enum FeatureFlags {
#if DEBUG
    static let experimentalReceiptLayouts = false
    static let experimentalCaptureModes = false
#else
    static let experimentalReceiptLayouts = false
    static let experimentalCaptureModes = false
#endif
}
