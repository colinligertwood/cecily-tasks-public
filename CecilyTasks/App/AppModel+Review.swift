import Foundation
import SwiftData
import TasksCore

extension AppModel {
    /// The weekly review's records.
    var reviews: [ReviewRecord] { (try? context.fetch(FetchDescriptor<ReviewRecord>())) ?? [] }

    /// Starts the weekly review, or goes back to the one open, at its next list.
    func startReview() {
        WeeklyReview.start(in: context)
        save()
        showNextReviewList()
    }

    /// Ticks `page` in the review and goes to the next list not ticked. Ticking the last finishes
    /// the review.
    func markReviewed(_ page: Page) {
        guard let list = page.reviewList else { return }
        WeeklyReview.tick(list, in: context)
        save()
        showNextReviewList()
    }

    /// Finishes the review, with whatever lists are ticked.
    func finishReview() {
        WeeklyReview.finish(in: context)
        save()
    }

    /// Shows the review's next list not ticked, while a review is open.
    func showNextReviewList() {
        let reviews = reviews
        guard WeeklyReview.current(reviews) != nil, let next = WeeklyReview.next(reviews) else { return }
        show(Page(next))
    }

    /// Shows `page`, with nothing selected or open over it.
    func show(_ page: Page) {
        self.page = page
        morePage = page == .someday || page == .reference ? page : nil
        selection = []
        openItem = nil
        openEvent = nil
    }
}
