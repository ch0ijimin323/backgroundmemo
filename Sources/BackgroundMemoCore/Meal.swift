import Foundation
import os

/// NEIS `MMEAL_SC_CODE`: 1, 2, 3.
public enum MealKind: Int, Codable, CaseIterable, Comparable, Sendable {
    case breakfast = 1
    case lunch = 2
    case dinner = 3

    public var title: String {
        switch self {
        case .breakfast: "조식"
        case .lunch: "중식"
        case .dinner: "석식"
        }
    }

    public static func < (lhs: MealKind, rhs: MealKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Meal: Codable, Equatable, Sendable {
    public var kind: MealKind
    /// `CAL_INFO` exactly as the API sent it, such as "658.6 Kcal". Empty when missing.
    public var calories: String
    /// One dish per entry, allergy numbers removed.
    public var dishes: [String]
    public init(kind: MealKind, calories: String, dishes: [String]) {
        self.kind = kind
        self.calories = calories
        self.dishes = dishes
    }
}

public struct MealDay: Codable, Equatable, Sendable {
    /// Unique by kind, in breakfast, lunch, dinner order. Empty means no meals that day.
    public var meals: [Meal]
    public init(meals: [Meal] = []) {
        self.meals = meals
    }

    public func meal(_ kind: MealKind) -> Meal? { meals.first { $0.kind == kind } }
}

/// The NEIS meal query for the configured school. The same service serves every kind of school.
public enum NEISMeal {
    public static let endpoint = "https://open.neis.go.kr/hub/mealServiceDietInfo"
    /// A day has at most three meals, so this is enough with or without a key.
    public static let pageSize = 5

    /// One day, always the first page. `dayKey` is "yyyy-MM-dd". Weekends are requested too.
    public static func requestURL(settings: SchoolSettings, dayKey: String, apiKey: String?) -> URL? {
        let ymd = dayKey.replacingOccurrences(of: "-", with: "")
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var components = URLComponents(string: endpoint)
        var items = [
            URLQueryItem(name: "Type", value: "json"),
            URLQueryItem(name: "pIndex", value: "1"),
            URLQueryItem(name: "pSize", value: String(pageSize)),
            URLQueryItem(name: "ATPT_OFCDC_SC_CODE", value: settings.officeCode),
            URLQueryItem(name: "SD_SCHUL_CODE", value: settings.schoolCode),
            URLQueryItem(name: "MLSV_FROM_YMD", value: ymd),
            URLQueryItem(name: "MLSV_TO_YMD", value: ymd),
        ]
        if !key.isEmpty { items.append(URLQueryItem(name: "KEY", value: key)) }
        components?.queryItems = items
        return components?.url
    }

    /// Parses a response body. INFO-200 is a valid day without meals; anything else unexpected throws.
    /// When `ymd` ("yyyyMMdd") is given, a row dated otherwise, or without a date, throws.
    public static func parse(_ data: Data, ymd: String? = nil) throws -> MealDay {
        guard let page = try NEISResponse.page(data, service: "mealServiceDietInfo") else { return MealDay() }
        var meals: [MealKind: Meal] = [:]
        for row in page.rows {
            // A row for any other day means the response cannot be trusted over the cached meals.
            if let ymd, row["MLSV_YMD"] as? String != ymd { throw TimetableError.malformedResponse }
            guard let code = NEISResponse.integer(row["MMEAL_SC_CODE"]) else { throw TimetableError.malformedResponse }
            // Other codes are not breakfast, lunch, or dinner, so they are not shown.
            guard let kind = MealKind(rawValue: code), meals[kind] == nil else { continue }
            meals[kind] = Meal(
                kind: kind,
                calories: row["CAL_INFO"] as? String ?? "",
                dishes: dishes(from: row["DDISH_NM"] as? String ?? "")
            )
        }
        return MealDay(meals: meals.values.sorted { $0.kind < $1.kind })
    }

    private static let lineBreak = try! NSRegularExpression(pattern: "<br\\s*/?>", options: [.caseInsensitive])
    /// A trailing group of allergy numbers such as "(5)", "(1.2.5.)" or "(5.6)".
    private static let allergyNumbers = try! NSRegularExpression(pattern: "\\s*\\(\\s*\\d+(?:\\s*\\.\\s*\\d+)*\\s*\\.?\\s*\\)\\s*$")
    private static let whitespaceRun = try! NSRegularExpression(pattern: "\\s+")

    /// Splits `DDISH_NM` on `<br/>`, drops each dish's trailing allergy numbers, and tidies spaces.
    /// Parentheses holding anything else, such as "(대)", stay. Empty dishes are dropped.
    public static func dishes(from text: String) -> [String] {
        let whole = NSRange(text.startIndex..., in: text)
        let marked = lineBreak.stringByReplacingMatches(in: text, range: whole, withTemplate: "\n")
        return marked.components(separatedBy: "\n").compactMap { line in
            var dish = line.trimmingCharacters(in: .whitespacesAndNewlines)
            while let match = allergyNumbers.firstMatch(in: dish, range: NSRange(dish.startIndex..., in: dish)),
                  let range = Range(match.range, in: dish) {
                dish.removeSubrange(range)
            }
            dish = whitespaceRun.stringByReplacingMatches(
                in: dish, range: NSRange(dish.startIndex..., in: dish), withTemplate: " "
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return dish.isEmpty ? nil : dish
        }
    }
}

public struct MealSnapshot: Equatable, Sendable {
    /// The latest successful result, which may come from the cache. Nil when there is none.
    public var day: MealDay?
    public var status: TimetableStatus
    public init(day: MealDay?, status: TimetableStatus) {
        self.day = day
        self.status = status
    }
}

struct MealCache: Codable, Equatable {
    /// `SchoolSettings.mealIdentity` of the school these days belong to.
    var identity: String?
    var days: [String: MealDay] = [:]

    init(identity: String?, days: [String: MealDay] = [:]) {
        self.identity = identity
        self.days = days
    }

    private enum CodingKeys: String, CodingKey { case identity, days }

    /// Files written before settings existed hold the old fixed school.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = container.contains(.identity)
            ? try container.decodeIfPresent(String.self, forKey: .identity)
            : SchoolSettings.legacyDefault.mealIdentity
        days = try container.decode([String: MealDay].self, forKey: .days)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identity, forKey: .identity)
        try container.encode(days, forKey: .days)
    }
}

/// Fetches and caches one calendar day at a time in meals.json under `AppPaths.root`, following the
/// timetable's rules: a failed fetch never changes the cache, a failed day waits before it is retried,
/// and save failures are logged and never block quitting. A cache saved for another school is ignored.
@MainActor
public final class MealStore {
    private static let logger = Logger(subsystem: "BackgroundMemo", category: "MealStore")
    private static let fileName = "meals.json"

    private struct InFlight {
        let token: UUID
        let task: Task<Void, Never>
    }

    /// Called whenever any day's snapshot may have changed.
    public var onUpdate: (() -> Void)?

    private let apiKey: @MainActor () -> String?
    private let transport: TimetableTransport
    private let failureCooldown: TimeInterval
    private let saver: CacheFileSaver

    public private(set) var settings: SchoolSettings?
    private var cache: MealCache
    private var fetchedThisSession: Set<String> = []
    private var failedDays: Set<String> = []
    private var lastFailure: [String: Date] = [:]
    private var inFlight: [String: InFlight] = [:]

    public init(
        paths: AppPaths,
        settings: SchoolSettings?,
        autosaveDelay: TimeInterval = 1.0,
        failureCooldown: TimeInterval = 30,
        apiKey: @escaping @MainActor () -> String?,
        transport: @escaping TimetableTransport = TimetableNetwork.live
    ) {
        self.failureCooldown = failureCooldown
        self.apiKey = apiKey
        self.transport = transport
        self.settings = settings
        let identity = settings?.mealIdentity
        let loaded = PlanStore.load(MealCache(identity: identity), from: paths.root.appendingPathComponent(Self.fileName))
        // Another school's meals are not shown; the file is replaced on the next successful fetch.
        cache = loaded.state.identity == identity ? loaded.state : MealCache(identity: identity)
        saver = CacheFileSaver(paths: paths, fileName: Self.fileName, autosaveDelay: autosaveDelay,
                               isBlocked: loaded.blocked, logger: Self.logger)
    }

    /// New settings. Changing the school empties the cache and meals.json, forgets this session's
    /// fetches and failures, and discards requests in flight; the caller then requests the day it shows.
    /// A new grade or class at the same school keeps the cache, since meals are per school.
    public func setSettings(_ newSettings: SchoolSettings?) {
        let changedSchool = newSettings?.mealIdentity != settings?.mealIdentity
        settings = newSettings
        guard changedSchool else {
            onUpdate?()
            return
        }
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        fetchedThisSession.removeAll()
        failedDays.removeAll()
        lastFailure.removeAll()
        cache = MealCache(identity: newSettings?.mealIdentity)
        // A nil identity is never written, so the file cannot be mistaken for the old fixed school.
        if newSettings != nil { saver.schedule(cache) }
        onUpdate?()
    }

    public func snapshot(for date: Date) -> MealSnapshot {
        guard settings != nil else { return MealSnapshot(day: nil, status: .unconfigured) }
        let day = PlannerState.dayKey(for: date)
        let cached = cache.days[day]
        if inFlight[day] != nil { return MealSnapshot(day: cached, status: .loading) }
        if failedDays.contains(day) { return MealSnapshot(day: cached, status: .failed) }
        return MealSnapshot(day: cached, status: cached == nil ? .loading : .loaded)
    }

    /// Fetches the day unless it is in flight, already succeeded this session, or failed moments ago.
    public func request(date: Date) {
        guard let settings else { return }
        let day = PlannerState.dayKey(for: date)
        guard !fetchedThisSession.contains(day), inFlight[day] == nil else { return }
        if let failed = lastFailure[day], Date().timeIntervalSince(failed) < failureCooldown { return }
        failedDays.remove(day)
        guard let url = NEISMeal.requestURL(settings: settings, dayKey: day, apiKey: apiKey()) else {
            failedDays.insert(day)
            onUpdate?()
            return
        }

        let ymd = day.replacingOccurrences(of: "-", with: "")
        let token = UUID()
        let transport = transport
        let task = Task { [weak self] in
            let outcome: Result<MealDay, TimetableError>
            do {
                let response = try await transport(url)
                guard response.statusCode == 200 else { throw TimetableError.http(response.statusCode) }
                outcome = .success(try NEISMeal.parse(response.data, ymd: ymd))
            } catch let error as TimetableError {
                outcome = .failure(error)
            } catch {
                // Never log `error` itself: URL errors include the failing URL, and so the key.
                Self.logger.error("Meal request failed, URL error code \((error as? URLError)?.code.rawValue ?? 0, privacy: .public)")
                outcome = .failure(.network)
            }
            self?.finish(day: day, token: token, outcome: outcome)
        }
        inFlight[day] = InFlight(token: token, task: task)
        onUpdate?()
    }

    /// Writes any pending cache change now. A failure is logged only; the data can be fetched again.
    public func flush() { saver.flush() }

    private func finish(day: String, token: UUID, outcome: Result<MealDay, TimetableError>) {
        guard inFlight[day]?.token == token else { return }
        inFlight[day] = nil
        switch outcome {
        case .success(let result):
            fetchedThisSession.insert(day)
            failedDays.remove(day)
            lastFailure[day] = nil
            if cache.days[day] != result {
                cache.days[day] = result
                saver.schedule(cache)
            }
        case .failure(let error):
            failedDays.insert(day)
            lastFailure[day] = Date()
            Self.logger.error("Meal fetch failed for \(day, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        onUpdate?()
    }
}
