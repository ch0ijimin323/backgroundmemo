import Foundation
import os

public struct TimetableEntry: Codable, Equatable, Sendable {
    public var period: Int
    public var subject: String
    public init(period: Int, subject: String) {
        self.period = period
        self.subject = subject
    }
}

public struct TimetableDay: Codable, Equatable, Sendable {
    /// Unique by period, ascending. Empty means there are no classes.
    public var entries: [TimetableEntry]
    /// True when the API reported more rows than it returned.
    public var isPartial: Bool
    public init(entries: [TimetableEntry] = [], isPartial: Bool = false) {
        self.entries = entries
        self.isPartial = isPartial
    }
}

/// Holds only codes, never a URL or message, so it is safe to log.
public enum TimetableError: Error, Equatable, Sendable {
    case network
    case http(Int)
    case malformedResponse
    case api(code: String)
}

/// The fixed NEIS query for this school and class.
public enum NEISTimetable {
    public static let endpoint = "https://open.neis.go.kr/hub/hisTimetable"
    public static let officeCode = "G10"
    public static let schoolCode = "7430310"
    public static let grade = "1"
    public static let classNumber = "1"
    /// The API's limit for callers without a key. Requests stay within it; they are never split or paged.
    public static let pageSizeWithoutKey = 5
    public static let pageSizeWithKey = 30

    /// One day, always the first page. `dayKey` is "yyyy-MM-dd".
    public static func requestURL(dayKey: String, apiKey: String?) -> URL? {
        let ymd = dayKey.replacingOccurrences(of: "-", with: "")
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var components = URLComponents(string: endpoint)
        var items = [
            URLQueryItem(name: "Type", value: "json"),
            URLQueryItem(name: "pIndex", value: "1"),
            URLQueryItem(name: "pSize", value: String(key.isEmpty ? pageSizeWithoutKey : pageSizeWithKey)),
            URLQueryItem(name: "ATPT_OFCDC_SC_CODE", value: officeCode),
            URLQueryItem(name: "SD_SCHUL_CODE", value: schoolCode),
            URLQueryItem(name: "GRADE", value: grade),
            URLQueryItem(name: "CLASS_NM", value: classNumber),
            URLQueryItem(name: "TI_FROM_YMD", value: ymd),
            URLQueryItem(name: "TI_TO_YMD", value: ymd),
        ]
        if !key.isEmpty { items.append(URLQueryItem(name: "KEY", value: key)) }
        components?.queryItems = items
        return components?.url
    }

    public static func isWeekend(_ date: Date, calendar: Calendar = .current) -> Bool {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let weekday = gregorian.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    /// Parses a response body. INFO-200 is a valid empty day; anything else unexpected throws.
    /// When `ymd` ("yyyyMMdd") is given, rows dated otherwise are ignored.
    public static func parse(_ data: Data, ymd: String? = nil) throws -> TimetableDay {
        guard let page = try NEISResponse.page(data, service: "hisTimetable") else { return TimetableDay() }
        let rows = page.rows

        var subjects: [Int: String] = [:]
        for row in rows {
            // A row for any other day means the response cannot be trusted over the cached timetable.
            if let ymd, row["ALL_TI_YMD"] as? String != ymd { throw TimetableError.malformedResponse }
            guard let period = NEISResponse.integer(row["PERIO"]), period > 0 else { throw TimetableError.malformedResponse }
            let subject = (row["ITRT_CNTNT"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !subject.isEmpty, subjects[period] == nil { subjects[period] = subject }
        }
        return TimetableDay(
            entries: subjects.sorted { $0.key < $1.key }.map { TimetableEntry(period: $0.key, subject: $0.value) },
            isPartial: page.total.map { $0 > rows.count } ?? false
        )
    }
}

/// The envelope shared by NEIS services: `{"<service>":[{"head":[…]},{"row":[…]}]}`,
/// or a top-level `{"RESULT":…}` for errors and empty results.
enum NEISResponse {
    struct Page {
        let rows: [[String: Any]]
        /// `list_total_count` from the head, when present.
        let total: Int?
    }

    private static let successCode = "INFO-000"
    private static let noDataCode = "INFO-200"

    /// The first page of rows, or nil for INFO-200 (no data). Any other result code throws `.api`,
    /// and an unexpected shape throws `.malformedResponse`.
    static func page(_ data: Data, service: String) throws -> Page? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TimetableError.malformedResponse
        }
        if let result = root["RESULT"] as? [String: Any] {
            guard let code = result["CODE"] as? String else { throw TimetableError.malformedResponse }
            guard code == noDataCode else { throw TimetableError.api(code: code) }
            return nil
        }
        guard let sections = root[service] as? [[String: Any]],
              let head = sections.lazy.compactMap({ $0["head"] as? [[String: Any]] }).first,
              let code = head.lazy.compactMap({ ($0["RESULT"] as? [String: Any])?["CODE"] as? String }).first
        else { throw TimetableError.malformedResponse }
        if code == noDataCode { return nil }
        guard code == successCode else { throw TimetableError.api(code: code) }
        guard let rows = sections.lazy.compactMap({ $0["row"] as? [[String: Any]] }).first else {
            throw TimetableError.malformedResponse
        }
        return Page(rows: rows, total: head.lazy.compactMap { integer($0["list_total_count"]) }.first)
    }

    static func integer(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return (value as? NSNumber)?.intValue
    }
}

public typealias TimetableTransport = @Sendable (URL) async throws -> (data: Data, statusCode: Int)

public enum TimetableNetwork {
    // The request URL can carry the API key, so nothing may be written to a disk cache.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    public static let live: TimetableTransport = { url in
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http.statusCode)
    }
}

public enum TimetableStatus: Equatable, Sendable {
    case loading
    case loaded
    case failed
}

public struct TimetableSnapshot: Equatable, Sendable {
    /// The latest successful result, which may come from the cache. Nil when there is none.
    public var day: TimetableDay?
    public var status: TimetableStatus
    public init(day: TimetableDay?, status: TimetableStatus) {
        self.day = day
        self.status = status
    }
}

struct TimetableCache: Codable, Equatable {
    var days: [String: TimetableDay] = [:]
}

/// Fetches and caches one day at a time in timetable.json under `AppPaths.root`.
/// A failed fetch never changes the cache. Save failures are logged and retried, and never block quitting.
@MainActor
public final class TimetableStore {
    private static let logger = Logger(subsystem: "BackgroundMemo", category: "TimetableStore")
    private static let fileName = "timetable.json"

    private struct InFlight {
        let token: UUID
        let task: Task<Void, Never>
    }

    /// Called whenever any day's snapshot may have changed.
    public var onUpdate: (() -> Void)?

    private let apiKey: @MainActor () -> String?
    private let transport: TimetableTransport
    private let failureCooldown: TimeInterval

    private var cache: TimetableCache
    private var fetchedThisSession: Set<String> = []
    private var failedDays: Set<String> = []
    private var lastFailure: [String: Date] = [:]
    private var inFlight: [String: InFlight] = [:]
    private let saver: CacheFileSaver

    public init(
        paths: AppPaths,
        autosaveDelay: TimeInterval = 1.0,
        failureCooldown: TimeInterval = 30,
        apiKey: @escaping @MainActor () -> String?,
        transport: @escaping TimetableTransport = TimetableNetwork.live
    ) {
        self.failureCooldown = failureCooldown
        self.apiKey = apiKey
        self.transport = transport
        let loaded = PlanStore.load(TimetableCache(), from: paths.root.appendingPathComponent(Self.fileName))
        cache = loaded.state
        saver = CacheFileSaver(paths: paths, fileName: Self.fileName, autosaveDelay: autosaveDelay,
                               isBlocked: loaded.blocked, logger: Self.logger)
    }

    public func snapshot(for date: Date) -> TimetableSnapshot {
        if NEISTimetable.isWeekend(date) { return TimetableSnapshot(day: TimetableDay(), status: .loaded) }
        let day = PlannerState.dayKey(for: date)
        let cached = cache.days[day]
        if inFlight[day] != nil { return TimetableSnapshot(day: cached, status: .loading) }
        if failedDays.contains(day) { return TimetableSnapshot(day: cached, status: .failed) }
        return TimetableSnapshot(day: cached, status: cached == nil ? .loading : .loaded)
    }

    /// Fetches the day unless it is a weekend, is in flight, or already succeeded this session.
    public func request(date: Date) {
        guard !NEISTimetable.isWeekend(date) else { return }
        let day = PlannerState.dayKey(for: date)
        guard !fetchedThisSession.contains(day), inFlight[day] == nil else { return }
        if let failed = lastFailure[day], Date().timeIntervalSince(failed) < failureCooldown { return }
        failedDays.remove(day)
        guard let url = NEISTimetable.requestURL(dayKey: day, apiKey: apiKey()) else {
            failedDays.insert(day)
            onUpdate?()
            return
        }

        let ymd = day.replacingOccurrences(of: "-", with: "")
        let token = UUID()
        let transport = transport
        let task = Task { [weak self] in
            let outcome: Result<TimetableDay, TimetableError>
            do {
                let response = try await transport(url)
                guard response.statusCode == 200 else { throw TimetableError.http(response.statusCode) }
                outcome = .success(try NEISTimetable.parse(response.data, ymd: ymd))
            } catch let error as TimetableError {
                outcome = .failure(error)
            } catch {
                // Never log `error` itself: URL errors include the failing URL, and so the key.
                Self.logger.error("Timetable request failed, URL error code \((error as? URLError)?.code.rawValue ?? 0, privacy: .public)")
                outcome = .failure(.network)
            }
            self?.finish(day: day, token: token, outcome: outcome)
        }
        inFlight[day] = InFlight(token: token, task: task)
        onUpdate?()
    }

    /// A new key was entered: partial days may be fetched again, and in-flight requests made
    /// without it are discarded. Refreshes `date`, the day being shown.
    public func apiKeyDidChange(refreshing date: Date) {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        fetchedThisSession = fetchedThisSession.filter { cache.days[$0]?.isPartial != true }
        request(date: date)
        onUpdate?()
    }

    /// Writes any pending cache change now. A failure is logged only; the data can be fetched again.
    public func flush() { saver.flush() }

    private func finish(day: String, token: UUID, outcome: Result<TimetableDay, TimetableError>) {
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
            Self.logger.error("Timetable fetch failed for \(day, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        onUpdate?()
    }
}

/// Debounced atomic writes of one cache file under `AppPaths.root`. The value is encoded when it is
/// scheduled, so a later write always holds the latest change. Failures are logged and retried, and
/// `flush` never reports them, because cached data can be fetched again.
@MainActor
final class CacheFileSaver {
    private let paths: AppPaths
    private let fileName: String
    private let autosaveDelay: TimeInterval
    private let isBlocked: Bool
    private let logger: Logger
    private var pending: Data?
    private var saveTask: Task<Void, Never>?

    init(paths: AppPaths, fileName: String, autosaveDelay: TimeInterval, isBlocked: Bool, logger: Logger) {
        self.paths = paths
        self.fileName = fileName
        self.autosaveDelay = autosaveDelay
        self.isBlocked = isBlocked
        self.logger = logger
    }

    func schedule(_ value: some Encodable) {
        guard !isBlocked else {
            logger.error("\(self.fileName, privacy: .public) could not be read, so it is not being overwritten")
            return
        }
        do { pending = try JSONEncoder().encode(value) }
        catch {
            logger.error("\(self.fileName, privacy: .public) encode failed: \(String(describing: error), privacy: .public)")
            return
        }
        saveTask?.cancel()
        armSave(after: max(0, autosaveDelay))
    }

    /// Writes any pending change now. A failure is logged and retried later.
    func flush() {
        guard pending != nil else { return }
        saveTask?.cancel()
        if !write() { armSave(after: max(1, autosaveDelay)) }
    }

    private func armSave(after delay: TimeInterval) {
        saveTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            if !self.write() { self.armSave(after: max(1, delay)) }
        }
    }

    private func write() -> Bool {
        guard let data = pending else { return true }
        do {
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try data.write(to: paths.root.appendingPathComponent(fileName), options: .atomic)
            pending = nil
            return true
        } catch {
            logger.error("\(self.fileName, privacy: .public) save failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
