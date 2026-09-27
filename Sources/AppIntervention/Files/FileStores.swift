import Foundation
import Synchronization

/// A ``PassStore`` in `passes.json`.
public final class FilePassStore: PassStore {
    private let file: EnvelopeFile<[Pass]>

    public convenience init(location: FileStoreLocation) throws(InterventionError) {
        self.init(resolved: try location.resolve())
    }

    public init(resolved: ResolvedFileStoreLocation) {
        file = EnvelopeFile(file: resolved.file("passes.json"))
    }

    public func allPasses() throws(InterventionError) -> [Pass] {
        try file.read() ?? []
    }

    @discardableResult
    public func update(appID: GuardedApp.ID, _ transform: (Pass?) -> Pass?) throws(InterventionError) -> Pass? {
        try file.modify { payload in
            var passes = payload ?? []
            let current = passes.first { $0.appID == appID }
            let next = transform(current)
            passes.removeAll { $0.appID == appID }
            if let next { passes.append(next) }
            passes.sort { $0.appID < $1.appID }
            payload = passes.isEmpty ? nil : passes
            return next
        }
    }
}

/// An ``InterventionHandoff`` in `pending-intervention.json`.
///
/// The file lets the context survive until a scene exists when the intent's process was launched
/// in the background; ``changes()`` is the fast in-process path.
public final class FileInterventionHandoff: InterventionHandoff {
    private let file: EnvelopeFile<InterventionContext>
    private let broadcaster = Broadcaster<Void>()

    public convenience init(location: FileStoreLocation) throws(InterventionError) {
        self.init(resolved: try location.resolve())
    }

    public init(resolved: ResolvedFileStoreLocation) {
        file = EnvelopeFile(file: resolved.file("pending-intervention.json"))
    }

    public func post(_ context: InterventionContext) throws(InterventionError) {
        try file.modify { $0 = context }
        broadcaster.yield(())
    }

    public func take(now: Date, maxAge: Duration) throws(InterventionError) -> InterventionContext? {
        let taken: InterventionContext? = try file.modify { payload in
            defer { payload = nil }
            return payload
        }
        guard let taken else { return nil }
        broadcaster.yield(())
        return InMemoryInterventionHandoff.fresh(taken, now: now, maxAge: maxAge)
    }

    public func changes() -> AsyncStream<Void> { broadcaster.stream() }
}

/// How long the open log keeps events.
public struct OpenLogRetention: Sendable, Hashable {
    public var maxAge: Duration
    public var maxCount: Int

    public init(maxAge: Duration = .seconds(90 * 86_400), maxCount: Int = 5_000) {
        self.maxAge = maxAge
        self.maxCount = max(1, maxCount)
    }
}

/// An ``OpenLogStore`` in `open-log.jsonl`, one event per line.
///
/// - Appending writes one line; it never rewrites the file.
/// - Lines with an unknown `kind` or a newer `v` are skipped by readers and **preserved** by
///   compaction, so an older build never destroys a newer build's events. Malformed lines are
///   skipped and dropped on compaction.
/// - Compaction (drop older than `maxAge`, keep the newest `maxCount`) runs when the line count
///   exceeds `maxCount × 1.25`, and on ``compact()``.
public final class FileOpenLogStore: OpenLogStore {
    package static let lineVersion = 1

    private let file: CoordinatedFile
    private let retention: OpenLogRetention
    private let clock: any InterventionClock
    private let cachedLineCount = Mutex<Int?>(nil)

    public convenience init(location: FileStoreLocation, retention: OpenLogRetention = .init(), clock: any InterventionClock = SystemClock()) throws(InterventionError) {
        self.init(resolved: try location.resolve(), retention: retention, clock: clock)
    }

    public init(resolved: ResolvedFileStoreLocation, retention: OpenLogRetention = .init(), clock: any InterventionClock = SystemClock()) {
        file = resolved.file("open-log.jsonl")
        self.retention = retention
        self.clock = clock
    }

    package struct Line: Codable {
        var v: Int
        var id: UUID
        var app: String
        var kind: String
        var t: Int64
        var tier: String?
        var ctx: UUID?
        var opt: String?
        var note: String?
    }

    private struct Probe: Decodable {
        var v: Int?
        var t: Int64?
    }

    public func append(_ event: OpenEvent) throws(InterventionError) {
        let line = Line(
            v: Self.lineVersion, id: event.id, app: event.appID, kind: event.kind.rawValue,
            t: WireCoding.epochMilliseconds(event.date), tier: event.tier?.rawValue,
            ctx: event.contextID, opt: event.optionID, note: event.note
        )
        var data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(line)
        } catch {
            throw InterventionError(.write, file: file.name, message: "Encoding failed", underlying: error as NSError)
        }
        data.append(0x0A)

        try file.withExclusiveAccess { url throws(InterventionError) in
            try file.append(data, to: url)
            let count = try currentLineCount(at: url, justAppended: true)
            if Double(count) > Double(retention.maxCount) * 1.25 {
                try compactLocked(at: url)
            }
        }
    }

    public func events(in interval: DateInterval?) throws(InterventionError) -> [OpenEvent] {
        let lines = try file.withExclusiveAccess { url throws(InterventionError) in try readLines(at: url) }
        let decoder = JSONDecoder()
        var events: [OpenEvent] = []
        for raw in lines {
            guard let line = try? decoder.decode(Line.self, from: Data(raw.utf8)),
                  line.v <= Self.lineVersion else { continue }
            let kind = OpenEvent.Kind(rawValue: line.kind)
            guard OpenEvent.Kind.known.contains(kind) else { continue }
            let date = WireCoding.date(epochMilliseconds: line.t)
            if let interval, !(interval.start <= date && date < interval.end) { continue }
            events.append(OpenEvent(
                id: line.id, appID: line.app, kind: kind, date: date,
                tier: line.tier.map(InterventionTier.init(rawValue:)), contextID: line.ctx, optionID: line.opt, note: line.note
            ))
        }
        return events.sorted { $0.date < $1.date }
    }

    /// Applies retention now.
    public func compact() throws(InterventionError) {
        try file.withExclusiveAccess { url throws(InterventionError) in try compactLocked(at: url) }
    }

    // MARK: - Private (inside exclusive access)

    private func readLines(at url: URL) throws(InterventionError) -> [String] {
        guard let data = try file.readData(at: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func currentLineCount(at url: URL, justAppended: Bool) throws(InterventionError) -> Int {
        let cached = cachedLineCount.withLock { value -> Int? in
            if let current = value, justAppended { value = current + 1 }
            return value
        }
        if let cached { return cached }
        let count = try readLines(at: url).count
        cachedLineCount.withLock { $0 = count }
        return count
    }

    private func compactLocked(at url: URL) throws(InterventionError) {
        let lines = try readLines(at: url)
        let cutoff = WireCoding.epochMilliseconds(clock.now.addingTimeInterval(-retention.maxAge.timeInterval))
        let decoder = JSONDecoder()
        let kept = lines.compactMap { raw -> (Int64, String)? in
            guard let probe = try? decoder.decode(Probe.self, from: Data(raw.utf8)), let t = probe.t else { return nil }
            return t >= cutoff ? (t, raw) : nil
        }
        let newest = kept.enumerated()
            .sorted { $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }
            .suffix(retention.maxCount)
            .map(\.element.1)
        var data = Data(newest.joined(separator: "\n").utf8)
        if !newest.isEmpty { data.append(0x0A) }
        try file.writeAtomically(data, to: url)
        cachedLineCount.withLock { $0 = newest.count }
    }
}
