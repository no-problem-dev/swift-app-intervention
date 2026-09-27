import AppIntervention
import AppInterventionFocus
import SwiftUI

/// DEBUG-only view of the stores: passes, the pending pause, the log tail, the session JSON.
struct StateScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let _ = model.revision
                let snapshot = QA.snapshot(model)
                List {
                    Section("Clock") { Text(Intervention.clock.now.formatted(date: .abbreviated, time: .standard)) }
                    Section("Passes") { Text(snapshot.passes).font(.callout.monospaced()) }
                    Section("Pending") { Text(snapshot.pending).font(.callout.monospaced()) }
                    Section("Log tail") { Text(snapshot.logTail).font(.callout.monospaced()) }
                    Section("Phone down") {
                        Text(snapshot.pd).font(.callout.monospaced())
                        Text(sessionJSON).font(.caption2.monospaced())
                    }
                    Section("Build") { Text(QA.buildUUID).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("State")
        }
    }

    private var sessionJSON: String {
        guard let session = model.phoneDown.session else { return "none" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(session)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }
}
