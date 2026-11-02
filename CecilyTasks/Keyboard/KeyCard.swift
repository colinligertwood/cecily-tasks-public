import SwiftUI

/// The keyboard shortcuts, in a sheet: a column for each job, headed by the job and where its keys
/// work or the keys it holds, each row the key tapped and what it does; the Mac's standards in a
/// row below, each chord in one cap; then what the modifier keys' symbols stand for. Every line is one line, the columns
/// share the card's width equally, and the sheet is as big as the card.
struct KeyCard: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
            card
                .fixedSize()
                .onExitCommand { dismiss() }
        #else
            ScrollView([.horizontal, .vertical]) { card.fixedSize() }
        #endif
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard Shortcuts")
                .font(.title3.weight(.semibold))
            EqualColumns(spacing: 32) {
                ForEach(KeyCommand.Job.allCases.filter { $0 != .standard }) { job in
                    let commands = KeyCommand.onCard.filter { $0.job == job }
                    if !commands.isEmpty { column(job, commands) }
                }
            }
            standards
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                ForEach(KeyCommand.legend, id: \.symbol) { key in
                    Text("\(key.symbol) \(key.name)")
                }
                Spacer(minLength: 24)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(24)
    }

    private func column(_ job: KeyCommand.Job, _ commands: [KeyCommand]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.rawValue)
                    .font(.headline)
                if let held = job.held {
                    HStack(spacing: 6) {
                        Text("Hold")
                        KeyCaps(caps: KeyCommand.caps(held))
                    }
                } else {
                    Text("Within lists")
                        .frame(minHeight: 22)
                }
            }
            .foregroundStyle(.secondary)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    if index > 0, commands[index - 1].group != command.group {
                        GridRow { Color.clear.frame(width: 1, height: 4).gridCellColumns(2) }
                    }
                    GridRow {
                        KeyCaps(caps: command.tapped)
                        Text(command.name)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(command.spoken)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var standards: some View {
        HStack(spacing: 18) {
            ForEach(KeyCommand.onCard.filter { $0.job == .standard }) { command in
                HStack(spacing: 6) {
                    KeyCaps(caps: [command.keys.joined()])
                    Text(command.name)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(command.spoken)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Keys, each in its own cap: at least as wide as it is tall, with its symbol centred. Dimmed, as
/// a hint beside something else, the cap is only outlined and its symbol lighter.
struct KeyCaps: View {
    let caps: [String]
    var isSmall = false
    var isDimmed = false

    var body: some View {
        HStack(spacing: isSmall ? 2 : 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: isSmall ? 10 : 13, weight: .medium))
                    .foregroundStyle(isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .padding(.horizontal, cap.count > 1 ? (isSmall ? 3 : 5) : 0)
                    .frame(minWidth: isSmall ? 16 : 22, minHeight: isSmall ? 16 : 22)
                    .background(isDimmed ? AnyShapeStyle(.clear) : AnyShapeStyle(.fill.tertiary), in: RoundedRectangle(cornerRadius: isSmall ? 4 : 5))
                    .overlay(RoundedRectangle(cornerRadius: isSmall ? 4 : 5).strokeBorder(.separator))
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// Columns side by side, each as wide as the widest, sharing any width they're offered beyond that
/// equally, and aligned at the top.
private struct EqualColumns: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = columnWidth(proposal, subviews)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
        return CGSize(width: width * CGFloat(subviews.count) + gaps(subviews), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = columnWidth(ProposedViewSize(width: bounds.width, height: nil), subviews)
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }

    /// The widest column's own width, or an equal share of `proposal`'s width when that's more.
    private func columnWidth(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        guard let offered = proposal.width, !subviews.isEmpty else { return widest }
        return max(widest, (offered - gaps(subviews)) / CGFloat(subviews.count))
    }

    private func gaps(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(subviews.count - 1, 0))
    }
}
