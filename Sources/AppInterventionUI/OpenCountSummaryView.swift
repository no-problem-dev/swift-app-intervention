import AppIntervention
import Charts
import SwiftUI

/// Today's opens, total and by hour. A lightweight summary; hosts with richer needs use
/// `OpenLogQuery` directly.
public struct OpenCountSummaryView: View {
    @Environment(\.interventionTheme) private var theme
    private let total: Int
    private let hours: [Int]

    public init(
        events: [OpenEvent], kind: OpenEvent.Kind = .opened, calendar: Calendar = .current,
        dayStartOffset: Duration = .zero, now: Date = .now
    ) {
        let query = OpenLogQuery(events, calendar: calendar, dayStartOffset: dayStartOffset)
        let today = query.day(containing: now)
        total = query.count(kind, in: today)
        hours = query.countsByHourOfDay(kind, in: today)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Opens today", bundle: .module)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Text(verbatim: "\(total)")
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(theme.primaryText)
            }
            Chart {
                ForEach(Array(hours.enumerated()), id: \.offset) { hour, count in
                    BarMark(x: .value("Hour", hour), y: .value("Opens", count))
                        .foregroundStyle(theme.accent)
                }
            }
            .chartXScale(domain: 0...23)
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18]) }
            .frame(height: 120)
            .accessibilityLabel(Text("Opens by hour", bundle: .module))
        }
    }
}
