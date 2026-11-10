import Foundation
import os

/// The kind of school, which picks the NEIS timetable service and the grade range.
public enum SchoolKind: String, Codable, CaseIterable, Sendable {
    case elementary
    case middle
    case high
    /// Special schools and anything else NEIS lists. Uses the high school timetable.
    case other

    /// From NEIS `SCHUL_KND_SC_NM`, such as "고등학교".
    public init(neisName: String) {
        switch neisName.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "초등학교": self = .elementary
        case "중학교": self = .middle
        case "고등학교": self = .high
        default: self = .other
        }
    }

    public var title: String {
        switch self {
        case .elementary: "초등학교"
        case .middle: "중학교"
        case .high: "고등학교"
        case .other: "기타"
        }
    }

    /// Elementary schools have six grades; the others three. Other schools allow six,
    /// since special schools can have elementary classes.
    public var grades: ClosedRange<Int> {
        switch self {
        case .elementary, .other: 1...6
        case .middle, .high: 1...3
        }
    }
}

/// One school, grade, and class, plus the bell schedule used to place its classes.
public struct SchoolSettings: Codable, Equatable, Sendable {
    /// NEIS `ATPT_OFCDC_SC_CODE`, such as "G10".
    public var officeCode: String
    /// NEIS `SD_SCHUL_CODE`, such as "7430310".
    public var schoolCode: String
    public var schoolName: String
    public var kind: SchoolKind
    public var grade: Int
    /// Sent as NEIS `CLASS_NM` exactly as entered (ends trimmed), so "1" or "가" both work.
    public var className: String
    /// Start of each period in minutes from midnight; index 0 is 1교시.
    public var periodStartMinutes: [Int]
    /// Length of every class in minutes.
    public var classLength: Int

    public init(
        officeCode: String, schoolCode: String, schoolName: String, kind: SchoolKind,
        grade: Int, className: String, periodStartMinutes: [Int], classLength: Int
    ) {
        self.officeCode = officeCode
        self.schoolCode = schoolCode
        self.schoolName = schoolName
        self.kind = kind
        self.grade = grade
        self.className = className.trimmingCharacters(in: .whitespacesAndNewlines)
        self.periodStartMinutes = periodStartMinutes
        self.classLength = classLength
    }

    private enum CodingKeys: String, CodingKey {
        case officeCode, schoolCode, schoolName, kind, grade, className, periodStartMinutes, classLength
    }

    /// Values that could not have been saved by the app make the file corrupt.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            officeCode: try container.decode(String.self, forKey: .officeCode),
            schoolCode: try container.decode(String.self, forKey: .schoolCode),
            schoolName: try container.decode(String.self, forKey: .schoolName),
            kind: try container.decode(SchoolKind.self, forKey: .kind),
            grade: try container.decode(Int.self, forKey: .grade),
            className: try container.decode(String.self, forKey: .className),
            periodStartMinutes: try container.decode([Int].self, forKey: .periodStartMinutes),
            classLength: try container.decode(Int.self, forKey: .classLength)
        )
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invalid school settings"))
        }
    }

    public static let maximumPeriods = 12
    public static let classLengthRange = 10...180

    public var isValid: Bool {
        !officeCode.isEmpty && !schoolCode.isEmpty && !schoolName.isEmpty
            && kind.grades.contains(grade) && !className.isEmpty
            && !periodStartMinutes.isEmpty && periodStartMinutes.count <= Self.maximumPeriods
            && periodStartMinutes.allSatisfy { (0..<1440).contains($0) }
            && Self.classLengthRange.contains(classLength)
    }

    /// Identifies the class whose timetable a cache holds.
    public var timetableIdentity: String {
        [officeCode, schoolCode, kind.rawValue, String(grade), className].joined(separator: "|")
    }

    /// Identifies the school whose meals a cache holds. Meals do not depend on the class.
    public var mealIdentity: String {
        [officeCode, schoolCode].joined(separator: "|")
    }

    /// "1학년 1반", or the class name as is when it is not a number.
    public var classTitle: String {
        let suffix = Int(className) != nil ? "반" : ""
        return "\(grade)학년 \(className)\(suffix)"
    }

    // MARK: Defaults

    public static let daedeokOfficeCode = "G10"
    public static let daedeokSchoolCode = "7430310"
    public static let daedeokPeriodStarts = [520, 580, 640, 700, 810, 870, 930, 980]
    public static let defaultClassLength = 50

    /// The school, class, and bell times this app had before settings existed.
    public static let legacyDefault = SchoolSettings(
        officeCode: daedeokOfficeCode, schoolCode: daedeokSchoolCode, schoolName: "대덕소프트웨어마이스터고등학교",
        kind: .high, grade: 1, className: "1",
        periodStartMinutes: daedeokPeriodStarts, classLength: defaultClassLength
    )

    /// 대덕소프트웨어마이스터고 keeps its own bell times. Every other school starts at 09:00 with
    /// 50-minute classes and 10-minute breaks, and a 60-minute lunch after 4교시 in place of that break,
    /// through 8교시.
    public static func defaultBell(officeCode: String, schoolCode: String) -> (periodStartMinutes: [Int], classLength: Int) {
        if officeCode == daedeokOfficeCode && schoolCode == daedeokSchoolCode {
            return (daedeokPeriodStarts, defaultClassLength)
        }
        let length = defaultClassLength
        var starts: [Int] = []
        var next = 9 * 60
        for period in 1...8 {
            starts.append(next)
            next += length + (period == 4 ? 60 : 10)
        }
        return (starts, length)
    }

    // MARK: Clock text

    /// "08:40" or "8:40" to minutes from midnight; nil for anything else.
    public static func minutes(fromClock text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// Minutes from midnight as "HH:mm".
    public static func clockText(_ minutes: Int) -> String {
        let value = ((minutes % 1440) + 1440) % 1440
        let hour = value / 60
        let minute = value % 60
        return (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
    }
}

public enum SchoolSettingsError: Error, Equatable, Sendable {
    /// school.json exists but could not be read, so it is not overwritten.
    case saveBlocked
}

/// What the app found in school.json at launch.
public struct LoadedSchoolSettings: Equatable, Sendable {
    public var settings: SchoolSettings?
    /// True for a new install, or after school.json was found corrupt: the settings window opens.
    public var needsSetup: Bool
    /// True when school.json exists but could not be read; it is then never overwritten.
    public var saveBlocked: Bool
    public init(settings: SchoolSettings?, needsSetup: Bool, saveBlocked: Bool) {
        self.settings = settings
        self.needsSetup = needsSetup
        self.saveBlocked = saveBlocked
    }
}

/// school.json under `AppPaths.root`, written atomically.
@MainActor
public final class SchoolSettingsStore {
    private static let logger = Logger(subsystem: "BackgroundMemo", category: "SchoolSettingsStore")
    public static let fileName = "school.json"

    private let paths: AppPaths
    private var saveBlocked = false
    private var file: URL { paths.root.appendingPathComponent(Self.fileName) }

    public init(paths: AppPaths) { self.paths = paths }

    /// Must run before the workspace is loaded, because loading creates workspace.json.
    /// - school.json present: used as saved. Corrupt: kept as a backup and the settings window opens.
    ///   Unreadable: never overwritten this session.
    /// - school.json missing and workspace.json present: an install from before settings existed,
    ///   so the old fixed school and class are saved and no window opens.
    /// - Both missing: a new install, so the settings window opens.
    public func load() -> LoadedSchoolSettings {
        let manager = FileManager.default
        if manager.fileExists(atPath: file.path) {
            let loaded = PlanStore.load(SchoolSettings?.none, from: file)
            saveBlocked = loaded.blocked
            // A corrupt file was moved aside, so the user picks the school again.
            return LoadedSchoolSettings(settings: loaded.state, needsSetup: loaded.state == nil && !loaded.blocked,
                                        saveBlocked: loaded.blocked)
        }
        guard manager.fileExists(atPath: paths.workspaceFile.path) else {
            return LoadedSchoolSettings(settings: nil, needsSetup: true, saveBlocked: false)
        }
        let migrated = SchoolSettings.legacyDefault
        do { try save(migrated) }
        catch { Self.logger.error("Migrated school settings save failed: \(String(describing: error), privacy: .public)") }
        return LoadedSchoolSettings(settings: migrated, needsSetup: false, saveBlocked: false)
    }

    public func save(_ settings: SchoolSettings) throws {
        guard !saveBlocked else { throw SchoolSettingsError.saveBlocked }
        guard settings.isValid else { throw CocoaError(.coderInvalidValue) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: file, options: .atomic)
    }
}

// MARK: School search

public struct SchoolSearchResult: Equatable, Sendable {
    public var name: String
    /// `SCHUL_KND_SC_NM` as sent, such as "고등학교" or "특수학교".
    public var kindName: String
    public var kind: SchoolKind
    public var officeCode: String
    public var schoolCode: String
    /// `LCTN_SC_NM`, such as "대전광역시".
    public var region: String
    public init(name: String, kindName: String, officeCode: String, schoolCode: String, region: String) {
        self.name = name
        self.kindName = kindName
        kind = SchoolKind(neisName: kindName)
        self.officeCode = officeCode
        self.schoolCode = schoolCode
        self.region = region
    }
}

public struct SchoolSearchPage: Equatable, Sendable {
    public var results: [SchoolSearchResult]
    /// The API holds more matches than it returned; the user should type a more exact name.
    public var hasMore: Bool
    public init(results: [SchoolSearchResult] = [], hasMore: Bool = false) {
        self.results = results
        self.hasMore = hasMore
    }
}

/// NEIS `schoolInfo` search by name. Always the first page; never paged around the keyless limit.
public enum NEISSchoolSearch {
    public static let endpoint = "https://open.neis.go.kr/hub/schoolInfo"
    public static let pageSizeWithoutKey = 5
    public static let pageSizeWithKey = 100

    /// Nil for a blank query.
    public static func requestURL(query: String, apiKey: String?) -> URL? {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var components = URLComponents(string: endpoint)
        var items = [
            URLQueryItem(name: "Type", value: "json"),
            URLQueryItem(name: "pIndex", value: "1"),
            URLQueryItem(name: "pSize", value: String(key.isEmpty ? pageSizeWithoutKey : pageSizeWithKey)),
            URLQueryItem(name: "SCHUL_NM", value: name),
        ]
        if !key.isEmpty { items.append(URLQueryItem(name: "KEY", value: key)) }
        components?.queryItems = items
        return components?.url
    }

    /// INFO-200 is no match. Rows without both codes or a name are skipped, since they cannot be chosen.
    public static func parse(_ data: Data) throws -> SchoolSearchPage {
        guard let page = try NEISResponse.page(data, service: "schoolInfo") else { return SchoolSearchPage() }
        func text(_ row: [String: Any], _ key: String) -> String {
            (row[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let results = page.rows.compactMap { row -> SchoolSearchResult? in
            let result = SchoolSearchResult(
                name: text(row, "SCHUL_NM"),
                kindName: text(row, "SCHUL_KND_SC_NM"),
                officeCode: text(row, "ATPT_OFCDC_SC_CODE"),
                schoolCode: text(row, "SD_SCHUL_CODE"),
                region: text(row, "LCTN_SC_NM")
            )
            return result.name.isEmpty || result.officeCode.isEmpty || result.schoolCode.isEmpty ? nil : result
        }
        return SchoolSearchPage(results: results, hasMore: page.total.map { $0 > page.rows.count } ?? false)
    }

    /// One request. Errors carry only codes, never the URL, because it can hold the key.
    public static func search(
        query: String, apiKey: String?, transport: TimetableTransport = TimetableNetwork.live
    ) async -> Result<SchoolSearchPage, TimetableError> {
        guard let url = requestURL(query: query, apiKey: apiKey) else { return .success(SchoolSearchPage()) }
        do {
            let response = try await transport(url)
            guard response.statusCode == 200 else { return .failure(.http(response.statusCode)) }
            return .success(try parse(response.data))
        } catch let error as TimetableError {
            return .failure(error)
        } catch {
            return .failure(.network)
        }
    }
}
