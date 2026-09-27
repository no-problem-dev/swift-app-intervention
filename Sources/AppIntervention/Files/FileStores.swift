import Foundation
import Synchronization

/// A ``PassStore`` in `passes.json`.
///
/// Instances on the same path share one lock in this process; cross-process locations are also
/// coordinated with `NSFileCoordinator`.
public final class FilePassStore: PassStore {
    private let file: EnvelopeFile<[Pass]>

    /// Never throws: the location is resolved on first use, and a failure there is reported by
    /// that call (the automation path then fails open).
    public init(location: FileStoreLocation) {
        file = EnvelopeFile(ref: FileRef(location: location, name: "passes.json"))
    }

    /// A store in an already resolved directory.
    public init(resolved: ResolvedFileStoreLocation) {
        file = EnvelopeFile(ref: FileRef(resolved: resolved, name: "passes.json"))
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
/// in the background; ``changes()`` is the fast in-process path, shared by every instance on the
/// same path.
public final class FileInterventionHandoff: InterventionHandoff {
    private let ref: FileRef
    private let file: EnvelopeFile<InterventionContext>

    /// Never throws; see ``FilePassStore/init(location:)``.
    public init(location: FileStoreLocation) {
        ref = FileRef(location: location, name: "pending-intervention.json")
        file = EnvelopeFile(ref: ref)
    }

    /// A handoff in an already resolved directory.
    public init(resolved: ResolvedFileStoreLocation) {
        ref = FileRef(resolved: resolved, name: "pending-intervention.json")
        file = EnvelopeFile(ref: ref)
    }

    public func post(_ context: InterventionContext) throws(InterventionError) {
        try file.modify { $0 = context }
        try ref.get().shared.handoffChanges.yield(.posted(context.id))
    }

    public func take(now: Date, maxAge: Duration) throws(InterventionError) -> InterventionContext? {
        let taken: InterventionContext? = try file.modify { payload in
            defer { payload = nil }
            return payload
        }
        guard let taken else { return nil }
        try ref.get().shared.handoffChanges.yield(.taken(taken.id))
        return isFresh(taken, now: now, maxAge: maxAge) ? taken : nil
    }

    public func withdraw(contextID: UUID) throws(InterventionError) {
        try file.modify { payload in
            if payload?.id == contextID { payload = nil }
        }
        try ref.get().shared.handoffChanges.yield(.withdrawn(contextID))
    }

    public func changes() -> AsyncStream<HandoffChange> {
        guard let file = try? ref.get() else { return AsyncStream { $0.finish() } }
        return file.shared.handoffChanges.stream()
    }
}

/// How long the open log keeps events.
public struct OpenLogRetention: Sendable, Hashable {
    /// Events older than this are dropped on compaction. Default 90 days.
    public var maxAge: Duration
    /// At most this many events are kept. Default 5,000.
    public var maxCount: Int

    public init(maxAge: Duration = .seconds(90 * 86_400), maxCount: Int = 5_000) {
        self.maxAge = maxAge
        self.maxCount = max(1, maxCount)
    }
}

/// An ``OpenLogStore`` in `open-log.jsonl`, one event per line.
///
/// - Appending writes one line with `O_APPEND`; it never rewrites the file. A torn last line
///   (from a crash mid-write) is terminated first so the new event survives.
/// - Lines with an unknown `kind` or a newer `v` are skipped by readers and **preserved** by
///   compaction, so an older build never destroys a newer build's events. Malformed lines are
///   skipped and dropped on compaction.
/// - Compaction (drop older than `maxAge`, keep the newest `maxCount`) runs when the line count
///   exceeds `maxCount × 1.25`, and on ``compact()``.
public final class FileOpenLogStore: OpenLogStore {
    package static let lineVersion = 1

    private let ref: FileRef
    private let retention: OpenLogRetention
    private let clock: any InterventionClock

    /// Never throws; see ``FilePassStore/init(location:)``.
    public init(location: FileStoreLocation, retention: OpenLogRetention = .init(), clock: any InterventionClock = SystemClock()) {
        ref = FileRef(location: location, name: "open-log.jsonl")
        self.retention = retention
        self.clock = clock
    }

    /// A log in an already resolved directory.
    public init(resolved: ResolvedFileStoreLocation, retention: OpenLogRetention = .init(), clock: any InterventionClock = SystemClock()) {
        ref = FileRef(resolved: resolved, name: "open-log.jsonl")
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
        let file = try ref.get()
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
            try file.appendLine(data, to: url)
            let count: Int
            if let cached = file.shared.lineCount {
                count = cached + 1
            } else {
                count = try readLines(file, at: url).count
            }
            file.shared.lineCount = count
            if Double(count) > Double(retention.maxCount) * 1.25 {
                try compactLocked(file, at: url)
            }
        }
    }

    public func events(in interval: DateInterval?) throws(InterventionError) -> [OpenEvent] {
        let file = try ref.get()
        let lines = try file.withExclusiveAccess { url throws(InterventionError) in try readLines(file, at: url) }
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
        let file = try ref.get()
        try file.withExclusiveAccess { url throws(InterventionError) in try compactLocked(file, at: url) }
    }

    // MARK: - Private (inside exclusive access)

    private func readLines(_ file: CoordinatedFile, at url: URL) throws(InterventionError) -> [String] {
        guard let data = try file.readData(at: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func compactLocked(_ file: CoordinatedFile, at url: URL) throws(InterventionError) {
        let lines = try readLines(file, at: url)
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
        file.shared.lineCount = newest.count
    }
}
