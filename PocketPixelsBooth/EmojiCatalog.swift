//
//  EmojiCatalog.swift
//  PocketPixelsBooth
//
//  Browsable, searchable Unicode emoji for Sticker Studio. Data comes from the bundled
//  `UnicodeEmojiCatalog.json`, generated from Unicode's official emoji-test.txt by
//  Tools/EmojiCatalog/make_emoji_catalog.py (Unicode License V3, docs/third-party).
//
//  This is a standards-based list, not a copy of Apple's keyboard: iOS has no public API for the
//  keyboard's exact contents. Newer entries are kept only when this iPad's system emoji font can
//  draw them as one glyph, and any emoji the guest picks from the system keyboard also works.
//

import Foundation

nonisolated struct EmojiEntry: Identifiable, Hashable, Sendable {
    let glyph: String
    /// Unicode CLDR short name, e.g. "grinning face".
    let name: String
    let subgroup: String
    let emojiVersion: Double
    /// Fully-qualified skin-tone forms, light to dark (empty when the emoji has none).
    let skinToneVariants: [String]

    var id: String { glyph }

    /// Lower-cased words used for offline search.
    var searchText: String {
        (name + " " + subgroup.replacingOccurrences(of: "-", with: " ")).lowercased()
    }

    /// Guest-facing name, e.g. "Grinning face".
    var displayName: String {
        name.prefix(1).uppercased() + name.dropFirst()
    }
}

nonisolated struct EmojiGroup: Identifiable, Hashable, Sendable {
    let key: String
    let unicodeName: String
    let entries: [EmojiEntry]

    var id: String { key }

    var displayName: String {
        switch key {
        case "smileys": "Smileys"
        case "people": "People"
        case "animals": "Animals"
        case "food": "Food"
        case "travel": "Travel"
        case "activities": "Activities"
        case "objects": "Objects"
        case "symbols": "Symbols"
        case "flags": "Flags"
        default: unicodeName
        }
    }

    var systemImage: String {
        switch key {
        case "smileys": "face.smiling"
        case "people": "hand.wave"
        case "animals": "pawprint"
        case "food": "fork.knife"
        case "travel": "car"
        case "activities": "soccerball"
        case "objects": "lightbulb"
        case "symbols": "heart"
        case "flags": "flag"
        default: "square.grid.2x2"
        }
    }
}

nonisolated final class EmojiCatalog: Sendable {
    let groups: [EmojiGroup]
    let unicodeVersion: String
    /// Entries skipped because this iPad's emoji font cannot draw them yet.
    let unsupportedCount: Int
    private let entriesByGlyph: [String: EmojiEntry]

    /// Emoji every recent iOS release renders; anything newer is checked against the system font.
    static let alwaysSupportedVersion = 15.0
    static let resourceName = "UnicodeEmojiCatalog"

    /// Loaded once, lazily, off the main thread when first touched from background work.
    static let shared = EmojiCatalog.load()

    /// A short starting palette shown before a guest has used anything.
    static let popularGlyphs = ["❤️", "😍", "🥰", "😂", "✨", "🎉", "🥳", "💕", "😎", "🌸", "⭐", "🔥", "👑", "💐", "🎂", "🎈", "😘", "🤍", "🌈", "🦋", "🙌", "👍", "💖", "🫶"]

    /// Everyday words guests type that CLDR names don't contain.
    static let synonyms: [String: [String]] = [
        "love": ["heart", "kiss", "love"],
        "lol": ["tears of joy", "rolling on the floor"],
        "haha": ["tears of joy", "grinning"],
        "happy": ["smiling", "grinning", "beaming"],
        "smile": ["smiling", "grinning"],
        "sad": ["crying", "frowning", "sad", "pensive"],
        "cry": ["crying", "sob"],
        "party": ["party", "confetti", "balloon", "celebration"],
        "celebrate": ["party", "confetti", "clinking", "sparkles", "fireworks"],
        "birthday": ["cake", "party", "balloon", "gift", "candle"],
        "wedding": ["ring", "wedding", "bride", "kiss", "couple"],
        "cool": ["sunglasses", "cool"],
        "cute": ["smiling face with hearts", "pleading", "bear", "cat", "rabbit", "flower"],
        "sparkle": ["sparkle", "glowing star"],
        "flower": ["flower", "blossom", "rose", "tulip", "bouquet", "hibiscus", "sunflower"],
        "drink": ["cup", "glass", "bottle", "tea", "coffee", "beer", "wine", "cocktail"],
        "philippines": ["philippines"],
        "pinoy": ["philippines"],
        "thanks": ["folded hands", "heart hands"],
        "ok": ["ok hand", "thumbs up", "check mark"],
        "yes": ["thumbs up", "check mark"],
        "christmas": ["christmas", "santa", "snowman", "gift"],
        "halloween": ["jack-o-lantern", "ghost", "skull", "bat"],
        "baby": ["baby"],
        "family": ["family"]
    ]

    init(groups: [EmojiGroup], unicodeVersion: String, unsupportedCount: Int = 0) {
        self.groups = groups
        self.unicodeVersion = unicodeVersion
        self.unsupportedCount = unsupportedCount
        var index: [String: EmojiEntry] = [:]
        for entry in groups.flatMap(\.entries) {
            index[entry.glyph] = entry
            for variant in entry.skinToneVariants where index[variant] == nil {
                index[variant] = entry
            }
        }
        entriesByGlyph = index
    }

    var allEntries: [EmojiEntry] { groups.flatMap(\.entries) }

    var totalSelectableCount: Int {
        allEntries.reduce(0) { $0 + 1 + $1.skinToneVariants.count }
    }

    /// The base entry for a glyph or any of its skin-tone forms.
    func entry(for glyph: String) -> EmojiEntry? {
        entriesByGlyph[glyph]
    }

    func group(key: String) -> EmojiGroup? {
        groups.first { $0.key == key }
    }

    var popularEntries: [EmojiEntry] {
        Self.popularGlyphs.compactMap { entry(for: $0) }
    }

    /// Every query word must match a name word (or one of its everyday synonyms). Results that
    /// start with the query rank first; otherwise catalog order is kept.
    func search(_ query: String, limit: Int = 240) -> [EmojiEntry] {
        let words = query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        // A typed or pasted emoji finds itself.
        if words.count == 1, let direct = entry(for: query.trimmingCharacters(in: .whitespaces)) {
            return [direct]
        }
        let needle = words.joined(separator: " ")
        var prefixed: [EmojiEntry] = []
        var others: [EmojiEntry] = []
        for entry in allEntries {
            let haystack = entry.searchText
            let matches = words.allSatisfy { word in
                Self.matches(word: word, in: haystack)
                    || (Self.synonyms[word]?.contains { haystack.contains($0) } ?? false)
            }
            guard matches else { continue }
            if entry.name.lowercased().hasPrefix(needle) { prefixed.append(entry) } else { others.append(entry) }
            if prefixed.count >= limit { break }
        }
        return Array((prefixed + others).prefix(limit))
    }

    /// Word-start matching ("cat" finds "cat face" but not "vacation"), with simple plurals.
    private static func matches(word: String, in haystack: String) -> Bool {
        let candidates = word.count > 3 && word.hasSuffix("s") ? [word, String(word.dropLast())] : [word]
        return candidates.contains { candidate in
            haystack.hasPrefix(candidate) || haystack.contains(" " + candidate)
        }
    }

    // MARK: Loading

    private struct File: Decodable {
        struct Group: Decodable {
            let key: String
            let name: String
            let emoji: [Item]
        }
        struct Item: Decodable {
            let g: String
            let n: String
            let s: String
            let e: String
            let v: [String]?
        }
        let unicodeVersion: String
        let groups: [Group]
    }

    static func load(bundle: Bundle = .main, supportCheck: (String) -> Bool = EmojiGlyphValidator.isSingleSystemEmojiGlyph) -> EmojiCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return EmojiCatalog(groups: [], unicodeVersion: "unavailable")
        }
        return decode(data, supportCheck: supportCheck) ?? EmojiCatalog(groups: [], unicodeVersion: "unavailable")
    }

    static func decode(_ data: Data, supportCheck: (String) -> Bool) -> EmojiCatalog? {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        var unsupported = 0
        let groups = file.groups.map { group in
            EmojiGroup(key: group.key, unicodeName: group.name, entries: group.emoji.compactMap { item in
                let version = Double(item.e) ?? 99
                if version > alwaysSupportedVersion, !supportCheck(item.g) {
                    unsupported += 1 + (item.v?.count ?? 0)
                    return nil
                }
                let variants = (item.v ?? []).filter { version <= alwaysSupportedVersion || supportCheck($0) }
                unsupported += (item.v?.count ?? 0) - variants.count
                return EmojiEntry(glyph: item.g, name: item.n, subgroup: item.s, emojiVersion: version, skinToneVariants: variants)
            })
        }
        .filter { !$0.entries.isEmpty }
        return EmojiCatalog(groups: groups, unicodeVersion: file.unicodeVersion, unsupportedCount: unsupported)
    }
}
