import Foundation

/// Value-only editor history. No persistence, media copies, printing or active-event mutation.
nonisolated struct ReceiptStudioHistory {
    private(set) var undoValues: [SavedEventDesign] = []
    private(set) var redoValues: [SavedEventDesign] = []
    private var lastKey: String?
    private var lastTime = Date.distantPast
    var canUndo: Bool { !undoValues.isEmpty }
    var canRedo: Bool { !redoValues.isEmpty }

    mutating func record(from before: SavedEventDesign, to after: SavedEventDesign, now: Date = Date()) {
        guard before != after else { return }
        let key = Self.changedPath(before, after)
        // A continuous slider/text burst is one adjustment. Switching fields/targets breaks it.
        if key == nil || key != lastKey || now.timeIntervalSince(lastTime) > 0.5 {
            undoValues.append(before)
            if undoValues.count > 60 { undoValues.removeFirst() }
        }
        redoValues.removeAll()
        lastKey = key; lastTime = now
    }
    mutating func endGroup() { lastKey = nil; lastTime = .distantPast }
    mutating func undo(_ current: SavedEventDesign) -> SavedEventDesign {
        guard let previous = undoValues.popLast() else { return current }
        redoValues.append(current); endGroup(); return previous
    }
    mutating func redo(_ current: SavedEventDesign) -> SavedEventDesign {
        guard let next = redoValues.popLast() else { return current }
        undoValues.append(current); endGroup(); return next
    }
    private static func changedPath(_ a: SavedEventDesign, _ b: SavedEventDesign) -> String? {
        func object(_ value: SavedEventDesign) -> NSDictionary? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
        }
        var paths: [String] = []
        func visit(_ a: NSDictionary, _ b: NSDictionary, _ prefix: String) {
            for key in Set(a.allKeys.compactMap { $0 as? String } + b.allKeys.compactMap { $0 as? String }) {
                let x = a[key], y = b[key], path = prefix + "." + key
                if let x = x as? NSDictionary, let y = y as? NSDictionary { visit(x, y, path) }
                else if !NSDictionary(dictionary: ["v": x ?? NSNull()]).isEqual(to: ["v": y ?? NSNull()]) { paths.append(path) }
            }
        }
        guard let a = object(a), let b = object(b) else { return nil }
        visit(a, b, "")
        // Enabling printed extras is derived from a caption/details edit, not a second user action.
        if paths.count > 1 { paths.removeAll { $0 == ".profile.receiptExtrasEnabled" } }
        return paths.count == 1 ? paths[0] : nil
    }
}

nonisolated enum ReceiptMovementPrecision: String, CaseIterable {
    case fine = "Fine", normal = "Normal", fast = "Fast"
    var dots: Double { switch self { case .fine: 1; case .normal: 4; case .fast: 12 } }
}

nonisolated enum ReceiptStudioLayout {
    static func previewWidth(for width: CGFloat, accessibility: Bool = false) -> CGFloat {
        let available = max(0, width - 53)
        return min(available * 0.60, max(280, available - (accessibility ? 320 : 290)))
    }
    static func usesColumns(width: CGFloat) -> Bool { width >= 680 }
}

extension SavedEventDesign {
    /// Commit only this editor's changed fields into the latest Setup value. Background server
    /// reconciliation can update commercial bindings while a receipt draft is open.
    nonisolated mutating func applyReceiptEdits(from draft: Self, baseline: Self) {
        guard id == draft.id, id == baseline.id else { return }
        if draft.personalizeReceipt != baseline.personalizeReceipt { personalizeReceipt = draft.personalizeReceipt }
        if draft.profile.receiptHeader != baseline.profile.receiptHeader { profile.receiptHeader = draft.profile.receiptHeader }
        if draft.profile.receiptDesign.typography != baseline.profile.receiptDesign.typography { profile.receiptDesign.typography = draft.profile.receiptDesign.typography }
        if draft.profile.receiptDesign.editorialCaption != baseline.profile.receiptDesign.editorialCaption { profile.receiptDesign.editorialCaption = draft.profile.receiptDesign.editorialCaption }
        if draft.profile.receiptDesign.footerStyleOverride != baseline.profile.receiptDesign.footerStyleOverride { profile.receiptDesign.footerStyleOverride = draft.profile.receiptDesign.footerStyleOverride }
        if draft.profile.receiptExtrasEnabled != baseline.profile.receiptExtrasEnabled { profile.receiptExtrasEnabled = draft.profile.receiptExtrasEnabled }
        if draft.profile.showEventTextBlock != baseline.profile.showEventTextBlock { profile.showEventTextBlock = draft.profile.showEventTextBlock }
        if draft.profile.subtitle != baseline.profile.subtitle { profile.subtitle = draft.profile.subtitle }
        if draft.profile.includeEventDate != baseline.profile.includeEventDate { profile.includeEventDate = draft.profile.includeEventDate }
        if draft.profile.eventDate != baseline.profile.eventDate { profile.eventDate = draft.profile.eventDate }
        if draft.profile.location != baseline.profile.location { profile.location = draft.profile.location }
        if draft.profile.shortMessage != baseline.profile.shortMessage { profile.shortMessage = draft.profile.shortMessage }
    }
}
