import CecilyKit
import SwiftUI

/// The Cecily brand in Cecily Tasks: its name, its icon's drawing and its tagline, which
/// CecilyKit draws in the About window.
extension AppBrand {
    static let tasks = AppBrand(name: "Tasks", icon: .tasksIcon, tagline: "A clear head, and time for what matters.")
}

extension PixelMap {
    /// The app icon's drawing, a daily planner lying open, 17 by 15 pixels with no tile: the book,
    /// down to its cover's bottom edge, centred on a 17 by 17 grid, with the ribbon hanging below to
    /// the grid's foot.
    static let tasksIcon = PixelMap(
        rows: [
            "KKKKKKKKKKKKKKKKK",
            "KRRRRRRRRRRRRRRRK",
            "KRWWWWWWKWWWWWWRK",
            "KRWRRWWWKWRRWWWRK",
            "KRWWWWWWKWWWWWWRK",
            "KRWKKKKWKWKKKKWRK",
            "KRWWWWWWKWWWWWWRK",
            "KRWKKKWWKWKKKWWRK",
            "KRWWWWWWKWWWWWWRK",
            "KRWSWKKWKWSWKKWRK",
            "KRWWWWWWKWWWWWWRK",
            "KRRRRRRRRRRRRRRRK",
            "KKKKKKKKKKKYYKKKK",
            "..........KYYK...",
            "..........KKKK...",
        ],
        colours: [
            "K": 0x1A1A1A,  // ink
            "W": 0xF9F5ED,  // paper, cream
            "S": 0x3C7A4A,  // done, green
            "R": 0xC0391B,  // cover, rust
            "Y": 0xE8B020,  // ribbon, gold
        ],
        origin: CGPoint(x: 0, y: 2),
        columns: 17
    )
}
