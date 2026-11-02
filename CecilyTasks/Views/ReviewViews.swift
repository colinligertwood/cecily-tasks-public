import SwiftData
import SwiftUI
import TasksCore

/// Whether a list has been reviewed in the weekly review: an empty circle, or ticked.
struct ReviewMark: View {
    let isReviewed: Bool
    /// Small, on a list's symbol, with the background behind it so it stands out from the
    /// symbol; otherwise the size of the text beside it.
    var isOnSymbol = true

    var body: some View {
        Image(systemName: isReviewed ? "checkmark.circle.fill" : "circle")
            .font(isOnSymbol ? .system(size: 11, weight: .semibold) : nil)
            .foregroundStyle(isReviewed ? Color.accentColor : Color.secondary)
            .background(isOnSymbol ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: .circle)
            .accessibilityLabel(isReviewed ? "Reviewed" : "Not reviewed yet")
    }
}

/// The weekly review's progress at the foot of the Mac's sidebar: how many lists are reviewed.
/// Clicking it goes to the next list; its menu finishes the review.
struct ReviewProgress: View {
    let ticked: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.showNextReviewList()
        } label: {
            HStack(spacing: 6) {
                Label("Review", systemImage: "checklist.checked")
                Spacer(minLength: 4)
                Text("\(ticked) of \(ReviewList.allCases.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Finish Review") { model.finishReview() }
        }
        .help("Weekly review: \(ticked) of \(ReviewList.allCases.count) lists reviewed")
        .accessibilityLabel("Weekly review, \(ticked) of \(ReviewList.allCases.count) lists reviewed")
    }
}

#if os(iOS)
    /// The weekly review's progress above the tabs: how many lists are reviewed. Tapping it opens
    /// the review's lists.
    struct ReviewBar: View {
        let open: () -> Void
        @Query private var reviews: [ReviewRecord]

        var body: some View {
            let ticked = WeeklyReview.ticked(reviews).count
            Button(action: open) {
                Label("Weekly Review · \(ticked) of \(ReviewList.allCases.count)", systemImage: "checklist.checked")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Weekly review, \(ticked) of \(ReviewList.allCases.count) lists reviewed")
        }
    }

    /// The weekly review's lists with whether each is reviewed, to go to one, and Finish Review.
    struct ReviewSheet: View {
        @Environment(AppModel.self) private var model
        @Environment(\.dismiss) private var dismiss
        @Query private var reviews: [ReviewRecord]

        var body: some View {
            let ticked = WeeklyReview.ticked(reviews)
            NavigationStack {
                List {
                    Section {
                        ForEach(ReviewList.allCases, id: \.self) { list in
                            let page = Page(list)
                            Button {
                                model.show(page)
                                dismiss()
                            } label: {
                                HStack {
                                    Label(page.rawValue, systemImage: page.symbol)
                                    Spacer()
                                    ReviewMark(isReviewed: ticked.contains(list), isOnSymbol: false)
                                }
                            }
                            .tint(.primary)
                        }
                    }
                    Section {
                        Button("Finish Review") {
                            model.finishReview()
                            dismiss()
                        }
                    }
                }
                .navigationTitle("Weekly Review")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

#endif
