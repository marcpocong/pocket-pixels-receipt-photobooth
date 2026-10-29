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
    /// Three-way, all-or-nothing commit. A conflicting save changes nothing; the operator can
    /// keep editing (including Undo) or explicitly reload the latest receipt. No force overwrite.
    @discardableResult
    nonisolated mutating func applyReceiptEdits(from draft: Self, baseline: Self) -> [String] {
        guard id == draft.id, id == baseline.id else { return ["Selected design"] }
        var candidate = self
        var conflicts: [String] = []
        func merge<Value: Equatable>(_ path: WritableKeyPath<Self, Value>, _ label: String) {
            let before = baseline[keyPath: path], edited = draft[keyPath: path], latest = self[keyPath: path]
            guard edited != before else { return }
            guard latest == before || latest == edited else { conflicts.append(label); return }
            candidate[keyPath: path] = edited
        }
        func mergeComponents<Value: Codable>(_ path: WritableKeyPath<Self, Value>, _ label: String) {
            do {
                candidate[keyPath: path] = try ReceiptComponentMerge.merge(
                    baseline[keyPath: path], draft[keyPath: path], self[keyPath: path],
                    label: label, conflicts: &conflicts)
            } catch { conflicts.append(label + " could not be read") }
        }
        merge(\.personalizeReceipt, "Personalization")
        mergeComponents(\.profile.receiptHeader, "Header")
        mergeComponents(\.profile.receiptDesign.typography, "Typography")
        merge(\.profile.receiptDesign.editorialCaption, "Caption")
        merge(\.profile.receiptDesign.footerStyleOverride, "Footer layout")
        merge(\.profile.receiptExtrasEnabled, "Printed extras")
        merge(\.profile.showEventTextBlock, "Event details")
        merge(\.profile.subtitle, "Subtitle")
        merge(\.profile.includeEventDate, "Show date")
        merge(\.profile.eventDate, "Date")
        merge(\.profile.location, "Location")
        merge(\.profile.shortMessage, "Message")
        if conflicts.isEmpty { self = candidate }
        return conflicts.sorted()
    }
}

/// Recurses through persisted header/typography components only. Missing optional components
/// are distinct from initialized geometry: simultaneous creation/reset is a component conflict,
/// rather than guessing reference coordinates. Existing components merge by individual property.
nonisolated private enum ReceiptComponentMerge {
    static func merge<Value: Codable>(_ baseline: Value, _ draft: Value, _ latest: Value,
                                       label: String, conflicts: inout [String]) throws -> Value {
        func object(_ value: Value) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        func equal(_ a: Any, _ b: Any) -> Bool {
            NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b])
        }
        func visit(_ before: Any, _ edited: Any, _ current: Any, _ path: String) -> Any {
            if equal(before, edited) { return current }
            if equal(before, current) || equal(edited, current) { return edited }
            if let before = before as? [String: Any], let edited = edited as? [String: Any],
               let current = current as? [String: Any] {
                var result = current
                for key in Set(before.keys).union(edited.keys).union(current.keys).sorted() {
                    let value = visit(before[key] ?? NSNull(), edited[key] ?? NSNull(),
                                      current[key] ?? NSNull(), path + "." + key)
                    if value is NSNull { result.removeValue(forKey: key) } else { result[key] = value }
                }
                return result
            }
            conflicts.append(path)
            return current
        }
        let merged = visit(try object(baseline), try object(draft), try object(latest), label)
        return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: merged))
    }
}
