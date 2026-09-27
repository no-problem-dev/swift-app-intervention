import AppIntervention
import AppInterventionFocus
import Foundation
import MachO

/// QA entry points. Everything here is compiled only in DEBUG; release builds get inert stubs.
///
/// Launch arguments:
///   -qa-reset                     delete this app's intervention files before launch
///   -qa-now <ISO8601>             use a manual clock starting at that instant
///   -qa-reopen accept|reject|none fake the reopen of the guarded app (none = real UIApplication.open)
///   -qa-pd-seconds <N>            start an N-second phone-down session at launch
///   -qa-script "<cmd>;<cmd>;…"    run the URL commands below in order (no `interventionsample://qa/`
///                                 prefix; `wait=N` pauses), `-qa-step-seconds` apart (default 2).
///                                 `make qa` uses this: the iOS 26 Simulator asks "Open in …?" for
///                                 every URL sent with `simctl openurl`, which blocks unattended runs.
///
/// URLs (`interventionsample://qa/...`):
///   run?app=instagram&fg=succeed|fail|unavailable|already   one simulated automation run
///   resolve?choice=pay|skip                                  resolve the pending pause
///   pass?app=instagram&sec=60                                grant a pass
///   advance?dt=60                                            move the manual clock
///   pd?event=start|bg|active|lock|unlock|expire|call1|call0|guarded|cancel&dt=+N&sec=N&app=…
///   tab?name=setup|opens|pd|state
///
/// After every action one line is printed:
///   [QA] action=… decision=… passes=… pending=… logTail=… pd=… buildUUID=…
enum QA {
    #if DEBUG
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    private static let arguments = ProcessInfo.processInfo.arguments

    private static func value(after flag: String) -> String? {
        guard isEnabled, let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static let clock: any InterventionClock = {
        if let iso = value(after: "-qa-now"), let date = ISO8601DateFormatter().date(from: iso) {
            return ManualClock(date)
        }
        return SystemClock()
    }()

    @MainActor
    static var reopener: (any AppReopener)? {
        switch value(after: "-qa-reopen") {
        case "accept": RecordingAppReopener { _ in true }
        case "reject": RecordingAppReopener { _ in false }
        default: nil
        }
    }

    static func prepareBeforeLaunch() {
        guard isEnabled else { return }
        // `simctl launch --stdout=<file>` is not a terminal: flush every line so the QA script sees it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard arguments.contains("-qa-reset"),
              let resolved = try? FileStoreLocation.applicationSupport.resolve() else { return }
        try? FileManager.default.removeItem(at: resolved.directory)
    }

    @MainActor
    static func startIfRequested(_ model: AppModel) async {
        if let seconds = value(after: "-qa-pd-seconds").flatMap(Int.init) {
            try? model.phoneDown.start(duration: .seconds(seconds))
            log("launch-pd", decision: "-", model: model)
        }
        guard let script = value(after: "-qa-script") else { return }
        let stepSeconds = value(after: "-qa-step-seconds").flatMap(Double.init) ?? 2
        try? await Task.sleep(for: .seconds(stepSeconds))
        var step = 0
        for command in script.split(separator: ";").map(String.init) where !command.isEmpty {
            if command.hasPrefix("wait=") {
                try? await Task.sleep(for: .seconds(Double(command.dropFirst(5)) ?? 1))
                continue
            }
            step += 1
            print("[QA] step=\(step) cmd=\(command)")
            if let url = URL(string: "interventionsample://qa/\(command)") {
                await handle(url, model: model)
            }
            try? await Task.sleep(for: .seconds(stepSeconds))
        }
        print("[QA] done steps=\(step)")
    }

    @MainActor
    static func handle(_ url: URL, model: AppModel) async {
        guard isEnabled, url.host() == "qa" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let action = url.lastPathComponent
        var decision = "-"

        if let dt = query("dt").flatMap({ Double($0.replacingOccurrences(of: "+", with: "")) }) {
            (clock as? ManualClock)?.advance(by: .milliseconds(Int64(dt * 1_000)))
        }
        let app = query("app") ?? "instagram"

        switch action {
        case "run":
            let behavior: StubForegroundContinuation.Behavior = switch query("fg") {
            case "fail": .fail
            case "unavailable": .unavailable
            case "already": .alreadyForeground
            default: .succeed
            }
            let outcome = await Intervention.coordinator.handleAutomationRun(appID: app, continuation: StubForegroundContinuation(behavior))
            decision = describe(outcome.decision)
            model.inbox.refresh()
        case "resolve":
            let presenter = model.makePresenter()
            do {
                if query("choice") == "skip" {
                    let receipt = try presenter.abandon(optionID: "skip")
                    decision = "abandoned:\(receipt.contextID.uuidString.prefix(8))"
                } else {
                    let result = try await presenter.proceed(optionID: "pay", passDuration: .seconds(15 * 60))
                    decision = "proceeded:\(result.reopen)"
                }
            } catch {
                decision = "error:\(error.code)"
            }
        case "pass":
            let seconds = query("sec").flatMap(Int64.init) ?? 60
            _ = try? Intervention.coordinator.grantPass(appID: app, duration: .seconds(seconds))
        case "advance":
            break
        case "pd":
            let now = clock.now
            switch query("event") {
            case "start": try? model.phoneDown.start(duration: .seconds(query("sec").flatMap(Int64.init) ?? 60))
            case "bg": model.phoneDown.handle(.enteredBackground(now))
            case "active": model.phoneDown.handle(.becameActive(now))
            case "lock": model.phoneDown.handle(.lockConfirmed(now))
            case "unlock": model.phoneDown.handle(.unlocked(now))
            case "expire": model.phoneDown.handle(.backgroundTimeExpired(now))
            case "call1": model.phoneDown.handle(.callChanged(active: true, at: now))
            case "call0": model.phoneDown.handle(.callChanged(active: false, at: now))
            case "guarded": model.phoneDown.handle(.guardedAppOpened(appID: app, at: now))
            case "tick": model.phoneDown.handle(.tick(now))
            case "cancel": model.phoneDown.cancel()
            default: break
            }
        case "tab":
            model.selectedTab = switch query("name") {
            case "opens": .opens
            case "pd": .phoneDown
            case "state": .state
            default: .setup
            }
        default:
            decision = "unknown-action"
        }
        model.revision += 1
        log(action, decision: decision, model: model)
    }

    // MARK: - Observation

    static func describe(_ decision: InterventionDecision) -> String {
        switch decision {
        case .intervene(let context): "intervene(\(context.reason),\(context.tier.rawValue))"
        case .passThrough(let reason): "passThrough(\(reason.note))"
        }
    }

    @MainActor
    static func snapshot(_ model: AppModel) -> (passes: String, pending: String, logTail: String, pd: String) {
        let now = clock.now
        let passes = ((try? Intervention.coordinator.passes.allPasses()) ?? []).map { pass in
            let left = Int(pass.expiresAt.timeIntervalSince(now))
            return "\(pass.appID):\(left)s\(pass.isInReturnWindow(at: now) ? "+return" : "")"
        }.joined(separator: ",")
        let pending = model.inbox.pending.map { "\($0.app.id)@\($0.id.uuidString.prefix(8))" } ?? "none"
        let tail = ((try? Intervention.coordinator.events(in: nil)) ?? []).suffix(4).map { event in
            event.note.map { "\(event.kind)(\($0))" } ?? "\(event.kind)"
        }.joined(separator: ",")
        let pd: String = switch model.phoneDown.session?.phase {
        case nil: "none"
        case .running(let away)?: away.map { "away(locked:\($0.lockConfirmed),undetermined:\($0.undetermined))" } ?? "running"
        case .succeeded?: "succeeded"
        case .failed(let reason)?: "failed(\(reason))"
        }
        return (passes.isEmpty ? "none" : passes, pending, tail.isEmpty ? "none" : tail, pd)
    }

    @MainActor
    static func log(_ action: String, decision: String, model: AppModel) {
        let s = snapshot(model)
        print("[QA] action=\(action) decision=\(decision) passes=\(s.passes) pending=\(s.pending) logTail=\(s.logTail) pd=\(s.pd) buildUUID=\(buildUUID)")
    }

    /// LC_UUID of the main executable: tells which build produced a log line.
    static let buildUUID: String = {
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), header.pointee.filetype == MH_EXECUTE else { continue }
            var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let load = command.assumingMemoryBound(to: load_command.self).pointee
                if load.cmd == UInt32(LC_UUID) {
                    let uuid = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                    return UUID(uuid: uuid).uuidString
                }
                command = command.advanced(by: Int(load.cmdsize))
            }
        }
        return "unknown"
    }()
}
