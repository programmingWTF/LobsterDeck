import SwiftUI

struct AgentOverviewCard: View {
    let repo: RepoStats
    var compact: Bool = false
    // The selected day in the 30-day chart. Lives here (not in the chart
    // itself) so the breakdown can sit below the axis labels, outside the
    // chart's fixed 92pt frame, without being clipped.
    @State private var selectedDay: DailyPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                tile("COMMITS", "\(repo.commits ?? 0)")
                tile("FILES", "\(repo.files ?? 0)")
                tile("REPO", repo.size ?? "-")
                tile("BRANCH", repo.branch ?? "-")
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip("数据源 Forgejo", color: .green)
                    chip("记忆文件 \(repo.memoryDirsWithMd ?? 0)/\(repo.memoryDirs ?? 0)", color: .yellow)
                    chip("最后提交 \(Fmt.relative(repo.lastCommit))", color: .orange)
                    chip("Markdown \(repo.markdownFiles ?? 0)", color: .blue)
                }
            }
            .scrollIndicators(.hidden)

            if !compact, let daily = repo.daily, !daily.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("近 30 天提交").font(.caption.weight(.semibold))
                        Spacer()
                        Text("点柱子看明细").font(.caption2).foregroundStyle(.tertiary)
                        Text(String(totalCommits(daily))).font(.caption2).foregroundStyle(.secondary)
                    }
                    ActivityChart(daily: daily, selected: $selectedDay)
                        .frame(height: 92)
                    axisLabels(daily)
                    if let day = selectedDay {
                        dayBreakdown(day)
                    }
                }
            }
        }
    }

    private func dayBreakdown(_ day: DailyPoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(dayLabel(day.date))
                    .font(.subheadline.weight(.semibold))
                Text("共 \(day.total) 次提交")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { selectedDay = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭明细")
            }
            if day.agents.isEmpty {
                Text("当天没有提交").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(day.agents.sorted(by: { $0.count > $1.count }), id: \.agent) { slice in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hexString: slice.color) ?? .gray)
                            .frame(width: 8, height: 8)
                        Text(slice.agent)
                            .font(.subheadline)
                        Spacer()
                        Text("\(slice.count) 次")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .padding(12)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12))
    }

    private func dayLabel(_ date: String) -> String {
        // Server daily dates are "YYYY-MM-DD".
        guard date.count >= 10 else { return date }
        let monthDay = String(date.dropFirst(5).prefix(5)).replacingOccurrences(of: "-", with: "月")
        return monthDay + "日"
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12))
    }

    private func chip(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.primary.opacity(0.05), in: .capsule)
        .overlay(Capsule().strokeBorder(.gray.opacity(0.2), lineWidth: 0.8))
    }

    private func axisLabels(_ daily: [DailyPoint]) -> some View {
        HStack {
            Text(short(daily.first?.date))
            Spacer()
            Text(short(daily[daily.count / 2].date))
            Spacer()
            Text(short(daily.last?.date))
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }

    private func totalCommits(_ daily: [DailyPoint]) -> Int {
        daily.reduce(0) { $0 + $1.total }
    }

    private func short(_ d: String?) -> String {
        guard let d, d.count >= 10 else { return "" }
        return String(d.dropFirst(5).prefix(5))
    }
}

struct ActivityChart: View {
    let daily: [DailyPoint]
    @Binding var selected: DailyPoint?

    var body: some View {
        GeometryReader { geo in
            let maxV = max(1, daily.map(\.total).max() ?? 1)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(daily) { day in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ForEach(day.agents, id: \.agent) { slice in
                            Rectangle()
                                .fill(Color(hexString: slice.color) ?? .gray)
                                .frame(height: max(1, CGFloat(slice.count) / CGFloat(maxV) * (geo.size.height - 2)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected?.id == day.id ? Color.primary.opacity(0.10) : Color.clear)
                    )
                }
            }
            .frame(height: geo.size.height, alignment: .bottom)
            .contentShape(Rectangle())
            // One tap gesture over the whole chart, mapping x -> day index.
            // The previous version used 30 tiny Buttons (~8pt wide each);
            // taps between columns, ScrollView tap delays, and Button hit
            // testing made those feel untappable. Mapping the tap location
            // makes every point in the chart, including gaps, select the
            // nearest day. Tap the same day again to deselect.
            .onTapGesture(coordinateSpace: .local) { location in
                guard !daily.isEmpty, geo.size.width > 0 else { return }
                let columnWidth = geo.size.width / CGFloat(daily.count)
                let index = min(max(Int(location.x / columnWidth), 0), daily.count - 1)
                let day = daily[index]
                selected = (selected?.id == day.id) ? nil : day
            }
            .accessibilityLabel("近 30 天提交图表，点某处查看那天各 Agent 的提交数")
        }
    }
}
