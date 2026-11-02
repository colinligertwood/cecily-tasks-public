import SwiftData
import SwiftUI
import TasksCore

/// A list's title menu on iPhone and iPad: what can be done to the list, its own first, then what
/// every list has. Greyed where it doesn't apply.
struct ListTitleMenu: View {
    let page: Page
    @Environment(AppModel.self) private var model
    @Query private var reviews: [ReviewRecord]
    @Query(filter: #Predicate<Item> { $0.bucketRaw == "trash" }) private var trashed: [Item]

    var body: some View {
        @Bindable var model = model
        switch page {
        case .agenda:
            if model.isReviewing {
                Button("Finish Review") { model.finishReview() }
            } else {
                Button("Start Review") { model.startReview() }
            }
            Divider()
        case .inbox:
            Button("Brain Dump…") { model.isBrainDumping = true }
            Divider()
        case .actions:
            ActionsViewOptions()
            Divider()
        case .trash:
            Button("Empty Trash…", role: .destructive) { model.isEmptyingTrash = true }
                .disabled(trashed.isEmpty)
            Divider()
        case .waiting, .someday, .reference:
            EmptyView()
        }
        if model.isReviewing, let list = page.reviewList {
            Button("Reviewed") { model.markReviewed(page) }
                .disabled(WeeklyReview.ticked(reviews).contains(list))
            Divider()
        }
        Toggle("Show Hidden", isOn: $model.showsHidden)
        Button("Export as Markdown…") { model.exportMarkdown(list: page) }
            .disabled(AppModel.markdownBucket(page) == nil)
    }
}

extension View {
    /// On iPhone and iPad, the list's title menu, with a small title, which is the one that can have
    /// a menu. The Mac's window title has no menu; its menu bar has these commands.
    @ViewBuilder func listTitleMenu(_ page: Page) -> some View {
        #if os(iOS)
            toolbarTitleMenu { ListTitleMenu(page: page) }
                .navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }
}
