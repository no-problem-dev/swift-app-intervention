import Foundation
import Testing
@testable import AppIntervention

@Suite("File stores", .timeLimit(.minutes(1)))
struct FileStoreTests {
    let directory = Fixture.temporaryDirectory()
    var location: FileStoreLocation { .directory(directory) }
    /// The stores resolve lazily; tests that write files by hand resolve first.
    var storeDirectory: URL { (try? location.resolve().directory) ?? directory.appending(path: "AppIntervention") }
    let now = Fixture.date(2026, 9, 27, 12)

    func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path(percentEncoded: false)).sorted()
    }

    // MARK: - Passes

    @Test("passes round-trip across instances, epoch-ms on disk")
    func passesRoundTrip() throws {
        let pass = Pass(appID: "instagram", grantedAt: now, expiresAt: now.addingTimeInterval(900), returnWindowEndsAt: now.addingTimeInterval(15))
        try FilePassStore(location: location).save(pass)
        #expect(try FilePassStore(location: location).pass(for: "instagram") == pass)

        let json = try String(contentsOf: storeDirectory.appending(path: "passes.json"), encoding: .utf8)
        #expect(json.contains("\"formatVersion\":1"))
        #expect(json.contains("\"grantedAt\":\(WireCoding.epochMilliseconds(now))"))
    }

    @Test("removing the last pass deletes the file; atomic writes leave no temporaries")
    func removeLast() throws {
        let store = FilePassStore(location: location)
        try store.save(Pass(appID: "a", grantedAt: now, expiresAt: now.addingTimeInterval(1)))
        try store.save(Pass(appID: "b", grantedAt: now, expiresAt: now.addingTimeInterval(1)))
        #expect(try contents() == ["passes.json"])
        try store.removeExpired(asOf: now.addingTimeInterval(2))
        #expect(try contents().isEmpty)
    }

    @Test("a corrupt file is quarantined and treated as empty")
    func corruptQuarantined() throws {
        let store = FilePassStore(location: location)
        try Data("{not json".utf8).write(to: storeDirectory.appending(path: "passes.json"))
        #expect(try store.allPasses().isEmpty)
        let names = try contents()
        #expect(names.count == 1)
        #expect(names[0].hasPrefix("passes.json.corrupt-"))
        try store.save(Pass(appID: "a", grantedAt: now, expiresAt: now.addingTimeInterval(1)))
        #expect(try store.allPasses().count == 1)
    }

    @Test("a payload that does not decode is quarantined too")
    func payloadCorrupt() throws {
        let store = FilePassStore(location: location)
        try Data(#"{"formatVersion":1,"payload":{"x":1}}"#.utf8).write(to: storeDirectory.appending(path: "passes.json"))
        #expect(try store.allPasses().isEmpty)
        #expect(try contents().first?.hasPrefix("passes.json.corrupt-") == true)
    }

    @Test("a newer envelope is refused and never overwritten")
    func newerEnvelope() throws {
        let url = storeDirectory.appending(path: "passes.json")
        let newer = Data(#"{"formatVersion":2,"payload":{"future":true}}"#.utf8)
        let store = FilePassStore(location: location)
        try newer.write(to: url)
        do {
            _ = try store.allPasses()
            Issue.record("expected unsupportedVersion")
        } catch {
            #expect(error.code == .unsupportedVersion)
        }
        #expect(throws: InterventionError.self) { try store.save(Pass(appID: "a", grantedAt: now, expiresAt: now)) }
        #expect(try Data(contentsOf: url) == newer)
    }

    @Test("cross-process locations coordinate and still round-trip")
    func crossProcess() throws {
        let store = FilePassStore(location: .directory(directory, crossProcess: true))
        try store.save(Pass(appID: "a", grantedAt: now, expiresAt: now.addingTimeInterval(1)))
        #expect(try store.allPasses().count == 1)
    }

    @Test("concurrent updates from many threads lose nothing")
    func concurrentUpdates() async throws {
        let store = FilePassStore(location: location)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask { _ = try? store.save(Pass(appID: "app\(i)", grantedAt: now, expiresAt: now.addingTimeInterval(60))) }
            }
        }
        #expect(try store.allPasses().count == 40)
    }

    // MARK: - Handoff

    @Test("handoff: post, take removes, stale is dropped, changes fire")
    func handoff() async throws {
        let handoff = FileInterventionHandoff(location: location)
        let changes = handoff.changes()
        let context = InterventionContext(app: Fixture.instagram, requestedAt: now, tier: "strict", reason: .locked(ruleID: "r", LockReason(id: "x", detail: "d")))
        try handoff.post(context)
        #expect(try FileInterventionHandoff(location: location).take(now: now.addingTimeInterval(10), maxAge: .seconds(120)) == context)
        #expect(try handoff.take(now: now, maxAge: .seconds(120)) == nil)

        try handoff.post(context)
        #expect(try handoff.take(now: now.addingTimeInterval(121), maxAge: .seconds(120)) == nil)
        #expect(try contents().isEmpty)

        // post, take (this instance), post, take (stale, still removed)
        let received = await collect(changes, count: 4)
        #expect(received == [.posted(context.id), .taken(context.id), .posted(context.id), .taken(context.id)])

    }

    // MARK: - Open log

    func event(_ kind: OpenEvent.Kind, _ offset: TimeInterval, app: String = "instagram") -> OpenEvent {
        OpenEvent(appID: app, kind: kind, date: now.addingTimeInterval(offset), tier: "t", contextID: UUID(), optionID: "o", note: "n")
    }

    @Test("open log round-trips every field and filters by interval")
    func logRoundTrip() throws {
        let store = FileOpenLogStore(location: location)
        let events = [event(.opened, 0), event(.intervened, 1), event(.proceeded, 2)]
        for e in events { try store.append(e) }
        #expect(try FileOpenLogStore(location: location).events(in: nil) == events)
        #expect(try store.events(in: DateInterval(start: now.addingTimeInterval(1), end: now.addingTimeInterval(2))) == [events[1]])
    }

    @Test("unknown kinds and newer lines are skipped by readers and preserved by compaction")
    func forwardCompatible() throws {
        let clock = ManualClock(now)
        let store = FileOpenLogStore(location: location, clock: clock)
        try store.append(event(.opened, 0))
        let url = storeDirectory.appending(path: "open-log.jsonl")
        let t = WireCoding.epochMilliseconds(now)
        let future = #"{"v":1,"id":"\#(UUID().uuidString)","app":"instagram","kind":"closed","t":\#(t)}"#
        let newer = #"{"v":2,"id":"\#(UUID().uuidString)","app":"instagram","kind":"opened","t":\#(t),"extra":[1]}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((future + "\n" + "garbage line\n" + newer + "\n").utf8))
        try handle.close()

        #expect(try store.events(in: nil).map(\.kind) == [.opened])
        try store.compact()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines.contains(future))
        #expect(lines.contains(newer))
        #expect(!lines.contains("garbage line"))
    }

    @Test("retention: compaction drops old events and keeps the newest maxCount")
    func retention() throws {
        let clock = ManualClock(now)
        let store = FileOpenLogStore(location: location, retention: OpenLogRetention(maxAge: .seconds(3_600), maxCount: 4), clock: clock)
        try store.append(event(.opened, -7_200))            // too old
        for i in 0..<4 { try store.append(event(.opened, Double(i))) }
        // 5 lines ≤ 4 × 1.25: no automatic compaction yet
        #expect(try store.events(in: nil).count == 5)
        try store.append(event(.opened, 10))                // 6 lines > 5 → compaction
        let kept = try store.events(in: nil)
        #expect(kept.count == 4)
        #expect(kept.map(\.date) == [1, 2, 3, 10].map { now.addingTimeInterval($0) })
    }
}
