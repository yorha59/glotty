import SwiftUI
import Charts

/// Settings → Polish → "Common mistake types" section. Used to render
/// a top-N list; now renders a per-category trend line chart over the
/// selected time range. Lines are scoped to the active polish target
/// language (categories are language-specific, so cross-language
/// counts would be apples-to-oranges).
///
/// Tap a series in the legend to drill into `MistakeTypeWindow` for
/// that category — same affordance the old list rows offered.
struct PolishCommonMistakesSection: View {
    @AppStorage("glotty.memory.range") private var rangeRaw: String = MemoryTimeRange.week.rawValue
    @AppStorage("glotty.polishLang") private var polishLang: String = "en"
    @State private var trendCategories: [String] = []
    @State private var trendPoints: [MemoryStore.GrammarIssueTrendPoint] = []
    /// Total distinct categories the language has in the current
    /// window (computed once per refresh). When `> defaultTopN`, the
    /// legend shows a "Show all (N)" toggle so the user can opt into
    /// the full set instead of just the top entries.
    @State private var totalCategoriesInRange: Int = 0
    @State private var showingAll: Bool = false

    /// Cap on series drawn by default. Picked to keep the chart
    /// readable on the standard Settings width (~480pt) — 10 lines
    /// is busy but still tractable, beyond that the lines stack on
    /// top of each other.
    private let defaultTopN = 10

    private var activeTopN: Int {
        showingAll ? max(totalCategoriesInRange, defaultTopN) : defaultTopN
    }

    private var range: MemoryTimeRange {
        MemoryTimeRange(rawValue: rangeRaw) ?? .week
    }

    var body: some View {
        Section {
            Picker("Show records from", selection: $rangeRaw) {
                ForEach(MemoryTimeRange.allCases) { range in
                    Text(range.label.t).tag(range.rawValue)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: rangeRaw) { _, _ in
                showingAll = false
                refresh()
            }
            .onChange(of: polishLang) { _, _ in
                showingAll = false
                refresh()
            }

            if trendCategories.isEmpty {
                Text("No mistake patterns yet. Polish will tag your drafts with categories (verb tense, articles, word choice, …) once it has rewritten a few.".t)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                trendChart
                legend
                if totalCategoriesInRange > defaultTopN {
                    showAllToggle
                }
            }
        } header: {
            Text("Common mistake types".t)
        } footer: {
            Text("Lines show how often Polish flagged each top category over the selected range. Click a legend entry to reopen the most recent run that flagged it.".t)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LocalizationCache.didUpdateNotification)) { _ in
            // No data refresh needed; modifier exists for parity
            // with other settings sections that observe the same
            // notification for re-render.
        }
    }

    private var trendChart: some View {
        Chart(trendPoints) { point in
            LineMark(
                x: .value("Date", point.bucketStart),
                y: .value("Mistakes", point.count)
            )
            .foregroundStyle(by: .value("Category", point.category))
            .interpolationMethod(.monotone)
            .symbol(by: .value("Category", point.category))
        }
        .chartForegroundStyleScale(domain: trendCategories)
        .chartSymbolScale(domain: trendCategories)
        .chartLegend(.hidden)   // custom legend below; built-in placement crowds the chart
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: xAxisFormat, centered: false)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: 180)
    }

    /// Tappable legend chips beneath the chart. The built-in
    /// `.chartLegend(.automatic)` works but doesn't accept gestures,
    /// so we render swatches manually and route taps into the same
    /// MistakeTypeWindow the old list rows opened.
    private var legend: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(trendCategories.enumerated()), id: \.offset) { idx, category in
                Button {
                    MistakeTypeWindowController.shared.show(category: category, range: range)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(seriesColor(for: idx))
                            .frame(width: 8, height: 8)
                        Text(category)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Expand-collapse control for the legend / chart. Shows the
    /// hidden count so the user knows what they're trading off.
    private var showAllToggle: some View {
        Button {
            showingAll.toggle()
            refresh()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showingAll ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                Text(showingAll
                     ? String(format: "Show top %@".t, "\(defaultTopN)")
                     : String(format: "Show all (%@)".t, "\(totalCategoriesInRange)"))
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    /// Match SwiftUI Charts' default palette for `foregroundStyle(by:)`
    /// indices 0…n so the legend swatches line up with the chart's
    /// drawn lines. The framework cycles through the system accent
    /// palette in order; we mirror that here.
    private func seriesColor(for index: Int) -> Color {
        // Chart's default palette is small; with up to ~15 lines on
        // "Show all" we extend it with mid-saturation distinct hues
        // so adjacent series in the legend stay visually separable.
        let palette: [Color] = [
            .blue, .green, .orange, .purple, .pink, .yellow,
            .red, .teal, .indigo, .mint, .cyan, .brown,
            Color(red: 0.55, green: 0.27, blue: 0.07),
            Color(red: 0.40, green: 0.70, blue: 0.30),
            Color(red: 0.85, green: 0.45, blue: 0.65),
        ]
        return palette[index % palette.count]
    }

    /// X-axis label format. Always shows a precise date (and time when
    /// the bucket size is sub-day) so the user can pinpoint when a
    /// spike happened, rather than just a weekday name.
    private var xAxisFormat: Date.FormatStyle {
        switch range {
        case .day:   return .dateTime.month(.abbreviated).day().hour()
        case .week:  return .dateTime.month(.abbreviated).day()
        case .month: return .dateTime.month(.abbreviated).day()
        case .all:   return .dateTime.year().month(.abbreviated).day()
        }
    }

    private func refresh() {
        // Total distinct categories in the window — used to decide
        // whether the "Show all (N)" toggle is meaningful and to
        // size the full-expand request below.
        totalCategoriesInRange = MemoryStore.shared
            .topGrammarIssues(limit: Int.max,
                              since: range.since(),
                              language: polishLang)
            .count
        let snapshot = MemoryStore.shared.grammarIssueTrend(
            topN: activeTopN,
            since: range.since(),
            language: polishLang
        )
        trendCategories = snapshot.categories
        trendPoints = snapshot.points
    }
}

/// Lightweight wrap-to-next-row layout for the legend chips. SwiftUI
/// doesn't ship one in HIG-conformant form for macOS yet; this is a
/// minimal implementation that's sufficient for ≤10 short labels.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > width, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width.isFinite ? width : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
