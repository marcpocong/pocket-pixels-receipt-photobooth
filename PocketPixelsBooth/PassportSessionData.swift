//
//  PassportSessionData.swift
//  PocketPixelsBooth
//
//  Session-local keepsake data for the Passport booth format. None of these values are
//  sent to the remote gallery; they live only in the active session, the local recovery
//  snapshot and the local Recent Sessions archive so exact reprints remain possible.
//

import CoreGraphics
import Foundation

// MARK: - Operator configuration

nonisolated enum PassportTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic
    case stars
    case minimal
    case event

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: "Classic"
        case .stars: "Stars"
        case .minimal: "Minimal"
        case .event: "Event"
        }
    }

    var summary: String {
        switch self {
        case .classic: "Double border, corner ornaments and a round keepsake stamp."
        case .stars: "Single border with star clusters and a star band under the title."
        case .minimal: "Clean single border, sans-serif title and no ornaments."
        case .event: "Ticket-style notched border with a dashed inner line and event stamp."
        }
    }
}

nonisolated enum PassportTitleSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case pocketPixels
    case eventText
    case eventHeaderGraphic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .pocketPixels: "Pocket Passport Branding"
        case .eventText: "Event Name"
        case .eventHeaderGraphic: "Event Header Graphic"
        }
    }

    var summary: String {
        switch self {
        case .automatic: "Uses the event header graphic when one is set, otherwise the event name, otherwise Pocket Passport branding."
        case .pocketPixels: "Always shows the Passport Title below."
        case .eventText: "Shows the event name with the event label underneath."
        case .eventHeaderGraphic: "Shows the custom event header artwork inside the passport card."
        }
    }
}

nonisolated struct PassportConfiguration: Codable, Equatable, Sendable {
    nonisolated static let titleLimit = 32
    nonisolated static let subtitleLimit = 48
    nonisolated static let eventLabelLimit = 32
    nonisolated static let defaultTitle = "POCKET PASSPORT"
    nonisolated static let defaultEventLabel = "EVENT PASSPORT"

    var theme: PassportTheme
    var titleSource: PassportTitleSource
    var title: String
    var subtitle: String
    var eventLabel: String

    nonisolated init(
        theme: PassportTheme = .classic,
        titleSource: PassportTitleSource = .automatic,
        title: String = PassportConfiguration.defaultTitle,
        subtitle: String = "",
        eventLabel: String = ""
    ) {
        self.theme = theme
        self.titleSource = titleSource
        self.title = title
        self.subtitle = subtitle
        self.eventLabel = eventLabel
    }

    nonisolated static let `default` = PassportConfiguration()

    enum CodingKeys: String, CodingKey {
        case theme
        case titleSource
        case title
        case subtitle
        case eventLabel
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? container.decodeIfPresent(PassportTheme.self, forKey: .theme)) ?? .classic
        titleSource = (try? container.decodeIfPresent(PassportTitleSource.self, forKey: .titleSource)) ?? .automatic
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? Self.defaultTitle
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        eventLabel = try container.decodeIfPresent(String.self, forKey: .eventLabel) ?? ""
    }

    nonisolated func normalized() -> PassportConfiguration {
        let normalizedTitle = PassportText.normalizedField(title, limit: Self.titleLimit)
        return PassportConfiguration(
            theme: theme,
            titleSource: titleSource,
            title: normalizedTitle.isEmpty ? Self.defaultTitle : normalizedTitle,
            subtitle: PassportText.normalizedField(subtitle, limit: Self.subtitleLimit),
            eventLabel: PassportText.normalizedField(eventLabel, limit: Self.eventLabelLimit)
        )
    }

    /// Simple Event Setup switch. On means event branding (automatic unless an advanced override
    /// is already saved); off forces Pocket Passport branding. Turning it on from off restores
    /// `.automatic`, and an existing `.eventText` / `.eventHeaderGraphic` override is never rewritten
    /// just by reading or re-enabling the switch.
    nonisolated var usesEventBranding: Bool {
        get { titleSource != .pocketPixels }
        set {
            if newValue {
                if titleSource == .pocketPixels { titleSource = .automatic }
            } else {
                titleSource = .pocketPixels
            }
        }
    }

    /// Passport customization belongs to printed-receipt event branding. Standard mode always
    /// uses the deterministic Pocket Pixels default.
    nonisolated static func effective(for eventProfile: EventProfile?) -> PassportConfiguration {
        eventProfile?.activeReceiptSnapshot?.passport.normalized() ?? .default
    }
}

// MARK: - Birthday

/// Month and day are required; the year is optional and only used to derive an age.
/// The year is dropped when the session is committed, so archives keep no more precision
/// than the receipt actually shows.
nonisolated struct PassportBirthday: Codable, Equatable, Sendable {
    nonisolated static let earliestYear = 1900

    var month: Int
    var day: Int
    var year: Int?

    nonisolated init(month: Int, day: Int, year: Int? = nil) {
        self.month = month
        self.day = day
        self.year = year
    }

    nonisolated static func maximumDay(month: Int, year: Int?) -> Int {
        switch month {
        case 2:
            guard let year else { return 29 }
            let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return isLeap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    nonisolated func normalized(referenceDate: Date = Date()) -> PassportBirthday? {
        guard (1...12).contains(month) else { return nil }
        let currentYear = PassportText.calendar.component(.year, from: referenceDate)
        let validYear = year.flatMap { (Self.earliestYear...currentYear).contains($0) ? $0 : nil }
        let clampedDay = min(max(1, day), Self.maximumDay(month: month, year: validYear))
        return PassportBirthday(month: month, day: clampedDay, year: validYear)
    }

    nonisolated func age(on date: Date) -> Int? {
        guard let year else { return nil }
        let components = PassportText.calendar.dateComponents([.year, .month, .day], from: date)
        guard let currentYear = components.year,
              let currentMonth = components.month,
              let currentDay = components.day else { return nil }
        var age = currentYear - year
        if currentMonth < month || (currentMonth == month && currentDay < day) {
            age -= 1
        }
        return (0...120).contains(age) ? age : nil
    }

    nonisolated var displayText: String {
        let monthIndex = min(max(month, 1), 12) - 1
        return "\(PassportText.monthAbbreviations[monthIndex]) \(day)"
    }
}

// MARK: - Signature

/// Resolution-independent signature strokes. Coordinates are quantized to
/// 0...coordinateScale in a fixed 4:1 canvas, so the same signature renders identically on
/// any screen size, in the receipt raster and in archived reprints.
nonisolated struct PassportSignature: Codable, Equatable, Sendable {
    nonisolated static let canvasAspectRatio: CGFloat = 4
    nonisolated static let coordinateScale = 1_000
    nonisolated static let maximumStrokes = 80
    nonisolated static let maximumPointsPerStroke = 600
    nonisolated static let maximumTotalPoints = 6_000

    nonisolated struct Stroke: Codable, Equatable, Sendable {
        /// Flattened x/y pairs in 0...coordinateScale.
        var coordinates: [Int]

        nonisolated var pointCount: Int { coordinates.count / 2 }
    }

    var strokes: [Stroke]

    nonisolated init(strokes: [Stroke] = []) {
        self.strokes = strokes
    }

    nonisolated static let empty = PassportSignature()

    nonisolated var isEmpty: Bool {
        strokes.allSatisfy { $0.pointCount == 0 }
    }

    nonisolated var totalPointCount: Int {
        strokes.reduce(0) { $0 + $1.pointCount }
    }

    /// Converts on-screen points into a normalized stroke. `canvasSize` is the signing view size.
    nonisolated static func stroke(from points: [CGPoint], canvasSize: CGSize) -> Stroke? {
        guard canvasSize.width > 0, canvasSize.height > 0, !points.isEmpty else { return nil }
        var coordinates: [Int] = []
        coordinates.reserveCapacity(min(points.count, maximumPointsPerStroke) * 2)
        for point in points.prefix(maximumPointsPerStroke) where point.x.isFinite && point.y.isFinite {
            coordinates.append(quantize(point.x / canvasSize.width))
            coordinates.append(quantize(point.y / canvasSize.height))
        }
        return coordinates.isEmpty ? nil : Stroke(coordinates: coordinates)
    }

    nonisolated func appending(_ stroke: Stroke) -> PassportSignature {
        PassportSignature(strokes: strokes + [stroke]).normalized()
    }

    nonisolated func removingLastStroke() -> PassportSignature {
        PassportSignature(strokes: Array(strokes.dropLast()))
    }

    nonisolated func normalized() -> PassportSignature {
        var remaining = Self.maximumTotalPoints
        var result: [Stroke] = []
        for stroke in strokes.prefix(Self.maximumStrokes) {
            guard remaining > 0 else { break }
            let evenCount = stroke.coordinates.count - (stroke.coordinates.count % 2)
            let pointLimit = min(evenCount / 2, Self.maximumPointsPerStroke, remaining)
            guard pointLimit > 0 else { continue }
            let clamped = stroke.coordinates.prefix(pointLimit * 2).map { min(max(0, $0), Self.coordinateScale) }
            result.append(Stroke(coordinates: Array(clamped)))
            remaining -= pointLimit
        }
        return PassportSignature(strokes: result)
    }

    /// The largest 4:1 rectangle that fits inside `rect`.
    nonisolated static func fittedRect(in rect: CGRect, alignment: CGFloat = 0.5) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return rect }
        let width = min(rect.width, rect.height * canvasAspectRatio)
        let height = width / canvasAspectRatio
        return CGRect(
            x: rect.minX + (rect.width - width) * min(max(alignment, 0), 1),
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    nonisolated func points(of stroke: Stroke, in rect: CGRect) -> [CGPoint] {
        stride(from: 0, to: stroke.coordinates.count - 1, by: 2).map { index in
            CGPoint(
                x: rect.minX + CGFloat(stroke.coordinates[index]) / CGFloat(Self.coordinateScale) * rect.width,
                y: rect.minY + CGFloat(stroke.coordinates[index + 1]) / CGFloat(Self.coordinateScale) * rect.height
            )
        }
    }

    /// Smoothed path drawn into a 4:1 rectangle. Single-point strokes become dots.
    nonisolated func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        for stroke in strokes {
            let points = points(of: stroke, in: rect)
            guard let first = points.first else { continue }
            path.move(to: first)
            if points.count == 1 {
                path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
                continue
            }
            if points.count == 2 {
                path.addLine(to: points[1])
                continue
            }
            for index in 1..<(points.count - 1) {
                let midpoint = CGPoint(
                    x: (points[index].x + points[index + 1].x) / 2,
                    y: (points[index].y + points[index + 1].y) / 2
                )
                path.addQuadCurve(to: midpoint, control: points[index])
            }
            if let last = points.last {
                path.addLine(to: last)
            }
        }
        return path
    }

    nonisolated private static func quantize(_ value: CGFloat) -> Int {
        Int((min(max(value, 0), 1) * CGFloat(coordinateScale)).rounded())
    }
}

// MARK: - Design version

/// Which receipt design a Passport session renders with. The stored `BoothFormat` stays
/// `.passport` for every version; only the card artwork and fields differ.
nonisolated enum PassportDesignVersion: String, Codable, CaseIterable, Sendable {
    /// The original Pocket Passport cards (birthday, nationality, profession, themes).
    case legacyPassport
    /// The template-based Photo Pass cards (name, date, event, location, notes, signature).
    case photoPassV2

    /// Design used for every new customer session.
    nonisolated static let current: PassportDesignVersion = .photoPassV2
    /// Design assumed for stored sessions written before the version field existed, so
    /// archived reprints never silently change their artwork.
    nonisolated static let decodingDefault: PassportDesignVersion = .legacyPassport
}

// MARK: - Session data

nonisolated struct PassportSessionData: Codable, Equatable, Sendable {
    nonisolated static let nameLimit = 32
    nonisolated static let nationalityLimit = 24
    nonisolated static let professionLimit = 32
    nonisolated static let birthplaceLimit = 24
    /// Enough for a short event note; the Photo Pass layout wraps it to at most three lines.
    nonisolated static let notesLimit = 60

    var name: String
    var birthday: PassportBirthday?
    var nationality: String
    var profession: String
    var birthplace: String
    /// Short optional note or message printed on the Photo Pass.
    var notes: String
    var signature: PassportSignature
    /// Theme and title settings frozen from the event profile when the format was chosen.
    var configuration: PassportConfiguration
    /// Age calculated once when the receipt is committed, so reprints never change.
    var frozenAge: Int?
    /// Receipt design frozen when the session was created.
    var designVersion: PassportDesignVersion

    nonisolated init(
        name: String = "",
        birthday: PassportBirthday? = nil,
        nationality: String = "",
        profession: String = "",
        birthplace: String = "",
        notes: String = "",
        signature: PassportSignature = .empty,
        configuration: PassportConfiguration = .default,
        frozenAge: Int? = nil,
        designVersion: PassportDesignVersion = .current
    ) {
        self.name = name
        self.birthday = birthday
        self.nationality = nationality
        self.profession = profession
        self.birthplace = birthplace
        self.notes = notes
        self.signature = signature
        self.configuration = configuration
        self.frozenAge = frozenAge
        self.designVersion = designVersion
    }

    nonisolated static let empty = PassportSessionData()

    enum CodingKeys: String, CodingKey {
        case name
        case birthday
        case nationality
        case profession
        case birthplace
        case notes
        case signature
        case configuration
        case frozenAge
        case designVersion
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        birthday = try container.decodeIfPresent(PassportBirthday.self, forKey: .birthday)
        nationality = try container.decodeIfPresent(String.self, forKey: .nationality) ?? ""
        profession = try container.decodeIfPresent(String.self, forKey: .profession) ?? ""
        birthplace = try container.decodeIfPresent(String.self, forKey: .birthplace) ?? ""
        // Added with Photo Pass. Missing or unreadable values never make a stored session unreadable.
        notes = (try? container.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        signature = try container.decodeIfPresent(PassportSignature.self, forKey: .signature) ?? .empty
        configuration = try container.decodeIfPresent(PassportConfiguration.self, forKey: .configuration) ?? .default
        frozenAge = try container.decodeIfPresent(Int.self, forKey: .frozenAge)
        designVersion = (try? container.decodeIfPresent(PassportDesignVersion.self, forKey: .designVersion)) ?? .decodingDefault
    }

    nonisolated var usesPhotoPassDesign: Bool {
        designVersion == .photoPassV2
    }

    nonisolated var hasAnyDetails: Bool {
        let value = normalized()
        return !value.name.isEmpty
            || value.birthday != nil
            || !value.nationality.isEmpty
            || !value.profession.isEmpty
            || !value.birthplace.isEmpty
            || !value.notes.isEmpty
    }

    nonisolated func normalized(referenceDate: Date = Date()) -> PassportSessionData {
        PassportSessionData(
            name: PassportText.normalizedField(name, limit: Self.nameLimit),
            birthday: birthday?.normalized(referenceDate: referenceDate),
            nationality: PassportText.normalizedField(nationality, limit: Self.nationalityLimit),
            profession: PassportText.normalizedField(profession, limit: Self.professionLimit),
            birthplace: PassportText.normalizedField(birthplace, limit: Self.birthplaceLimit),
            notes: PassportText.normalizedField(notes, limit: Self.notesLimit),
            signature: signature.normalized(),
            configuration: configuration.normalized(),
            frozenAge: frozenAge.flatMap { (0...120).contains($0) ? $0 : nil },
            designVersion: designVersion
        )
    }

    /// Age shown on the card. Committed data uses the frozen value; drafts calculate it live.
    nonisolated func displayAge(referenceDate: Date) -> Int? {
        frozenAge ?? birthday?.age(on: referenceDate)
    }

    /// Freezes the derived age and drops the birth year, which is no longer needed.
    nonisolated func committed(at date: Date) -> PassportSessionData {
        var value = normalized(referenceDate: date)
        value.frozenAge = value.displayAge(referenceDate: date)
        value.birthday?.year = nil
        return value
    }

    /// Gallery copy of the receipt: photos and branding only, with every customer-entered
    /// detail, the note and the signature removed. The design version is kept so the gallery
    /// copy uses the same artwork as the printed receipt.
    nonisolated func redactedForGallery() -> PassportSessionData {
        PassportSessionData(configuration: configuration.normalized(), designVersion: designVersion)
    }
}

// MARK: - Text helpers

nonisolated enum PassportText {
    nonisolated static let monthAbbreviations = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    nonisolated static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ReceiptComposer.sessionIdentifierTimeZone
        return calendar
    }()

    /// Single line, collapsed whitespace, no control characters, limited by visible characters
    /// so emoji and combined Unicode sequences are never split.
    nonisolated static func normalizedField(_ value: String, limit: Int) -> String {
        // Only C0/C1 control characters are removed; format characters such as the emoji
        // zero-width joiner must survive so emoji sequences are not broken apart.
        let withoutControls = String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
            scalar.properties.generalCategory != .control || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }))
        let collapsed = withoutControls
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return String(collapsed.prefix(max(0, limit))).trimmingCharacters(in: .whitespaces)
    }

    /// Keeps a live text field within its limit without normalizing whitespace mid-typing.
    nonisolated static func limitedInput(_ value: String, limit: Int) -> String {
        let singleLine = value.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > limit ? String(singleLine.prefix(limit)) : singleLine
    }

    nonisolated static func printed(_ value: String) -> String {
        value.uppercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

#if DEBUG
// MARK: - Debug fixtures (synthetic values only)

extension PassportSignature {
    /// Deterministic looping signature used for layout development and tests.
    nonisolated static var debugFixture: PassportSignature {
        var coordinates: [Int] = []
        for step in 0...120 {
            let t = Double(step) / 120
            let x = 0.06 + t * 0.70
            let y = 0.55 - sin(t * .pi * 6) * 0.22 * (1 - t * 0.4) - t * 0.08
            coordinates.append(Int((x * 1_000).rounded()))
            coordinates.append(Int((min(max(y, 0.05), 0.95) * 1_000).rounded()))
        }
        let underline = [80, 860, 300, 830, 560, 800, 840, 780]
        return PassportSignature(strokes: [Stroke(coordinates: coordinates), Stroke(coordinates: underline)])
    }
}

extension PassportSessionData {
    /// Legacy Pocket Passport fixture (birthday, nationality, profession).
    nonisolated static var debugFixture: PassportSessionData {
        PassportSessionData(
            name: "Sarah Aragão",
            birthday: PassportBirthday(month: 4, day: 20, year: 1998),
            nationality: "Brazilian",
            profession: "Model",
            signature: .debugFixture,
            designVersion: .legacyPassport
        )
    }

    /// Photo Pass fixture used for layout development, tests and debug renders.
    nonisolated static var photoPassDebugFixture: PassportSessionData {
        PassportSessionData(
            name: "Karynne Jaca",
            notes: "Keep this little moment.",
            signature: .debugFixture,
            designVersion: .photoPassV2
        )
    }
}
#endif

extension PassportSessionData {
    /// Synthetic sample used by the operator receipt preview in Event Setup.
    nonisolated static func operatorPreviewSample(configuration: PassportConfiguration) -> PassportSessionData {
        let coordinates = stride(from: 0, through: 100, by: 2).flatMap { step -> [Int] in
            let t = Double(step) / 100
            let y = 0.5 - sin(t * .pi * 5) * 0.2
            return [Int((0.08 + t * 0.66) * 1_000), Int(y * 1_000)]
        }
        return PassportSessionData(
            name: "Alex Rivera",
            notes: "Best night of the year.",
            signature: PassportSignature(strokes: [.init(coordinates: coordinates)]),
            configuration: configuration,
            designVersion: .current
        )
    }
}
