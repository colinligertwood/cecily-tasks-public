# Cecily Tasks

A task and notes app for the Mac and iPhone. Everything that has your attention goes into the Inbox, gets decided on and put in its place, is gone over once a week, and is there to choose from when you have a moment. It's one of the Cecily apps, with Cecily Budget and Cecily Cards.

## What it does

- **Capture:** add to the Inbox from the window, the menu bar, a quick-entry panel that opens over any app on the Mac (⌃⌥Space), or the Share menu. Quick capture reads tokens such as `@errands`, `#project` and `due:fri`. A brain dump walks through prompts to empty your head into the Inbox.
- **Decide:** file each item to Actions, Waiting, Someday, Reference or the Trash, or schedule it for a day, from its menu or the keyboard. Every decision can be undone.
- **The lists:** Actions grouped by context, project or area and filtered by time, energy and what's due; Waiting by who it's waiting for; Someday; Reference; and the Trash, which empties itself after 30 days.
- **Agenda:** today and the weeks ahead, with what's scheduled, due or to follow up, and your calendars' events. A meeting's note in Reference, linked to its calendar event, holds the things to raise there.
- **Tasks with subtasks,** and subtasks of their own, done in any order or one at a time; notes in Markdown, with links to other items; attachments, photos and scanned documents; repeats on a schedule or after each is done; hiding an item until a day; areas and contexts.
- **The weekly review:** a mode that ticks off each list as you go through it, with a reminder.
- **Search,** Export as Markdown…, and Back Up… and Restore from Backup….
- **iCloud:** your tasks sync between your Mac, iPhone and iPad, in your private iCloud database.

## Requirements

- macOS 26 or iOS 26, or later, to run it.
- Xcode 27 to build it. Xcode fetches its one package from outside this repository, CecilyKit (shared by the Cecily apps), from GitHub.
- Node.js and npm only to rebuild the notes editor.

## Building

Open `CecilyTasks.xcodeproj` in Xcode, or build from the command line without signing:

```bash
xcodebuild -scheme 'Cecily Tasks' -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme 'Cecily Tasks' -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

An unsigned build keeps everything on the device: iCloud needs a signed build with its entitlements.

### Signing with your own team

`Signing.xcconfig` is every target's base configuration, and includes `Local.xcconfig` beside it, which Git ignores. Make one with your Apple developer team:

```
DEVELOPMENT_TEAM = <your team ID>
```

The identifiers below belong to the published app, so a build of your own needs its own. Change each to something under your own reverse domain:

| What | Identifier | Where it's set |
| --- | --- | --- |
| The app | `com.ligertwood.cecily.tasks` | `PRODUCT_BUNDLE_IDENTIFIER` in the project |
| The Share extension | `com.ligertwood.cecily.tasks.Share` | the same |
| The tests | `com.ligertwood.cecily.tasks.tests` | the same |
| The App Group, where the store is kept so the Share extension can add to it | `group.com.ligertwood.cecily.tasks` | the four `.entitlements` files and `StoreFolder.appGroup` |
| The iCloud container | `iCloud.com.ligertwood.cecily.tasks` | `CecilyTasks.entitlements`, `CecilyTasks-iOS.entitlements` and `CloudSync.containerID` |

Xcode's automatic signing then registers them for your team.

### iCloud

A debug build, run from Xcode, syncs with the container's Development environment and keeps a store of its own, "Cecily Tasks (Development)" in the App Group's folder, so it never touches a release build's tasks. Before sync can work in a new container, run the app from Xcode once with `-tasks-cloudkit-schema` (in the Cecily Tasks scheme's arguments, unticked): it writes every record type and field into the Development schema and quits. Deploy the schema to Production in CloudKit Console before shipping a release build.

## Tests

```bash
swift test --package-path Packages/TasksCore
xcodebuild test -scheme 'Cecily Tasks' -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme 'Cecily Tasks' -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

TasksCore's tests cover the model, repeats, the lists' rules, capture, export and sync, the last against a stand-in for CloudKit. The app's tests run inside the app, in a store in memory. Swift is formatted with `swift format` and the repository's `.swift-format`:

```bash
swift format lint --strict --recursive --parallel CecilyTasks CecilyTasksTests Share Packages/TasksCore/Sources Packages/TasksCore/Tests
```

GitHub Actions runs all of these on each push to `main` and each pull request (`.github/workflows/tests.yml`). Warnings fail the build.

## The notes editor

Notes are edited in a web view with CodeMirror 6 and ProseMark. Its source is `Editor/src/editor.js`; the bundle the app loads, `CecilyTasks/Editor/editor.js`, is committed, so building the app doesn't need npm. After changing the source or its packages, rebuild the bundle:

```bash
cd Editor && npm ci && npm run build
```

## How it's built

- **App** (`CecilyTasks/`): one SwiftUI target for macOS and iOS 26.0 and later.
  - `App/AppModel`: what the windows share: the store's main context, sync, the day, and saving, with its other parts in extensions by area: `AppModel+Capture` (capture and new items), `+Filing`, `+Review`, `+Undo` (each decision registered with the window's undo manager), `+Trash`, `+Meetings` and `+Subtasks` (subtasks, repeats, hiding, and dragging rows).
  - `App/Notifier`: the pending notifications, kept the same as TasksCore's `NotificationPlan` with the weekly review's reminders, and opening the item a tapped one is for, or starting the review.
  - `App/Brand`: the app's brand as `AppBrand.tasks`, its name, tagline and its icon's pixel map (a daily planner lying open), from which CecilyKit, the package the Cecily apps share, draws the Mac's About window (Cecily Tasks ▸ About Cecily Tasks): the drawing without its tile, CECILY with its rust square and Tasks in Silom, the version, "A clear head, and time for what matters." and the copyright.
  - `App/CalendarFeed`: the device's calendars and their events from EventKit, whether they're on and each calendar's reach (kept on the device), read again when the calendars change, the app comes to the front or the day changes.
  - `App/CecilyTasksApp`: `Store` opens a store and its model: the person's own in the App Group container (`group.com.ligertwood.cecily.tasks`), which extensions can open too, copied there from Application Support the first time; a debug build, which syncs with iCloud's Development environment, has a store of its own there, "Cecily Tasks (Development)", and keeps sync's settings apart (`CloudSync.defaults`), so it never touches a release build's, which syncs with Production; `Stores` holds the one that's open. `App/PreviewRecords` gives previews a few made-up records in memory (`#Preview(traits: .previewRecords)`).
  - `Views/Style`: the interface's spacing scale (`Spacing`), the text style each kind of text uses (`Font.openTitle`, `.panelTitle`, `.cardHeading`, `.rowTitle`, the system's size on the Mac and iPhone, which the notes editor's text follows, `.detail`), the cards' frame (`cardChrome`), a row's leading mark (`RowMark`), the empty list (`EmptyList`), and `displayTitle` for an item or area with no name. Done and cancelled titles are struck through and grey; what's chosen or highlighted is in the system accent colour; words that name something are in title case, and sentences in sentence case.
  - `Views/RootView`: the lists (`Page`) and the window, with `MacNavigation`, the sidebar and the Mac's toolbar, and `PhoneNavigation`, the tabs on iPhone with More. `AgendaView`, `NotificationSettingsView`, `InboxView`, `ActionsView` (with `ActionsViewOptions`, its grouping and filters), `SubtasksSection`, `WaitingView`, `SomedayView`, `ReferenceView`, `TrashView`, `BrainDumpView`, `SettingsView` (with `AreasAndContextsSettings` and `CalendarSettings`), and `Lists` (`AreaFilter`, and whether an item is in an area). `ReviewViews`: in the weekly review, `ReviewMark` and `ReviewProgress` in the Mac's sidebar, and the bar above the tabs with its sheet on iPhone.
  - `Views/AttachmentsSection`: an open item's attachments, their menus, the ways to add one (`AttachmentMenuItems`), dropping files on an item, and the panels for choosing files, the camera and the document scanner; `App/AppModel+Attachments` adds and deletes them, with Undo.
  - `Views/ItemRow`: an item's row. `DetailTags`: its details as tags (`ItemDetails`, `TagView`, `FieldTag`), each opening an editor from `DetailEditors`, which the inspector uses too. `Inspector`: `ItemInspector` and `SelectionInspector`, for one item or the selection (`AppModel.selection`). `ItemCard`: `OpenTaskContent`, an open item. `ListActions`: what every list does with its rows: the selection's menus, opening, dragging and dropping. `Editing/DoneTypingField`: a field that saves what's typed when it's done.
  - `Views/Capture/`: `CaptureView` (quick capture in a sheet, on iPhone) and, on the Mac, quick entry: `QuickEntryView`, the Markdown editor in large type, its first line the title and the rest notes, with the inspector's details in columns along its bottom, and `QuickCapturePanel`, the Spotlight-like floating panel it's in, its system-wide shortcut and the menu-bar icon that opens it.
  - `Editing/`: `NoteDraft`, an item's notes as Markdown, saved as they're typed, which can make its item on the first save; `ItemNotes`, which edits them in the Markdown editor, adding files pasted or dropped into them as attachments, and `EventItemNotes`, an open event's, in its linked note.
  - `Editor/`: `MarkdownWebEditor`, the Markdown editor's web view, and its page, `editor.html` and `editor.js`, built from the top-level `Editor/` folder.
  - `Sync/CloudSync`: turns iCloud sync on and off (on at first launch when signed in), and runs `CloudKitSyncEngine` and `TasksSync` for the store.
- **Share Sheet** (`Share/`): an app extension for iPhone and the Mac, embedded in the app. `ShareInput` reads what was shared (a link, text or a file), `ShareView` shows it with its title to change, and `ShareStore` adds it to the store in the App Group container as an Inbox item. It never syncs: the app picks its saves up when it comes to the front (`AppModel.readOutsideSaves`) and syncs them. It refuses to add anything until the app has moved its store to the App Group.
- **Editor** (`Editor/`): the Markdown editor's page script, `src/editor.js`, and its npm packages (CodeMirror 6 and ProseMark). `npm ci && npm run build` there writes `CecilyTasks/Editor/editor.js`, which is committed.
- **TasksCore** (`Packages/TasksCore/`): logic with no screen, tested with `swift test`.
  - `Model/`: the SwiftData model (`Item`, `Area`, `Context`, `Repetition`, `Attachment`, `ReviewRecord`, `AppSettings`), and `ConflictedCopy`, kept on the device only. A task's subtasks are its `children`. `AreasAndContexts` renames, orders, hides and deletes areas and contexts. `ItemEditing` says which details each list's items have, how items sit in the tree (`project`, the task an item is under; `depth`, `ancestors`, `descendants`), makes new items and subtasks, and sets details. `Shared`: what several items have for one detail, for the combined inspector. `StoreFolder`: the store's folder in the App Group container, and the one-time copy into it.
  - `Attachments/`: `AttachedFile`, a file to keep as an attachment, read with its type and refused over 50 MB, attaching it to an item, and putting a deleted one back (`Attachment.Kept`); `Thumbnail`, a file's thumbnail from Quick Look, and an image made smaller to show.
  - `Capture/`: `CaptureParser` reads quick-capture text and its tokens; `Capture` adds it to the Inbox, one item per line, or for quick entry one item with its first line the title and the rest notes, with the details chosen for it (`CaptureDetails`); `SharedItem` makes an Inbox item from what the Share Sheet was given; `BrainDump` holds the prompts.
  - `Clarify/`: `ClarifyOutcome`, where an item is filed and what's filled in; `Clarifier`, which files an item and undoes it, and `Decisions`, a task's Someday and Drop, hiding, and making subtasks by dragging, undone the same way (an undo holds the earlier fields of each record it changed, and can say how they are now, for redo).
  - `Lists/`: `TrashList`, what's in the Trash, Put Back, Empty Trash and deleting after 30 days; `DayBoundary`, when each day starts (04:00 unless set otherwise); `ListRules`, what puts an item in a list on a given day: hidden until a later day, stalled (a task with subtasks, none of them a next step), and in Actions (scheduled actions from their day, and under a task that's One at a Time, only its first open subtask); `ListRows`, a list's items as rows with subtasks under their task (those open or done today), a list's order (`Item.inListOrder`, `Item.putInOrder`) and grouping by area; `Timeline`, Agenda's stops, where each item is on them, each stop's parts, and the next four weeks for the weekly review; `CalendarEvents`, a calendar's events (`CalendarEvent`, `CalendarReach`) and which stops they're on, the meeting note an event's series is linked to, the repeating series to choose from, and linking and New Note as decisions that can be undone (`AgendaEvents`); `ActionsList`, Actions' groups (by context, project, area or none), filters (`ActionsFilter`: time, energy, due within a week) and the weekly review's unchanged actions; `WaitingList`, Waiting's groups, with Nudge and Take Back; `SomedayList`, Someday's groups, with Activate; `EventLocation`, an event's location without its rooms' names or its meeting's service and link; `ReferenceList`, Reference's groups by area and project.
  - `Export/`: `FullExport`, everything as a folder (the records as JSON, attachments as files, and Markdown), and restoring it into an empty store; `MarkdownExport`, an item or a list as Markdown, and a task's open subtasks as a checklist.
  - `Notes/`: `MarkdownText`, notes' Markdown as one line of plain words, for a row's preview and search; `NoteLink`, links in notes to items and areas, the ones to offer and their current titles; `WebLinkTitle`, a pasted web address and its page's title.
  - `Lists/ListSelection`: a list's selection as its rows change.
  - `Search/ItemSearch`: finding items by the starts of the words in their titles, notes and attachments' names, with filters, grouped by list; `RecentSearches`, the last searches.
  - `Notify/NotificationPlan`: the notifications wanted from the items and the settings, soonest first, at most 60, and the weekly review's reminders.
  - `Review/WeeklyReview`: the weekly review: the lists in it (`ReviewList`), the review open, starting, ticking and finishing, whether it's missed, and when the reminder comes.
  - `Repeat/`: `LocalDate`, a calendar day with no time or time zone, with day and month arithmetic; `Recurrence`, a repeat on a schedule, read from and written as an RRULE (`FREQ` daily to yearly, `INTERVAL`, `BYDAY` with ordinals, `BYMONTHDAY`, `BYMONTH`, `BYSETPOS`, `COUNT`, `UNTIL`, `WKST`); `Occurrences`, the dates a rule falls on, period by period; `RepeatRule`, the two repeat modes (on a schedule, or after completion), show early, end date and remaining count, and the next copy's date; `RepeatCopies`, the next copy a repeating item makes when it's done, taken back when it's opened again, with `Clarifier.toggleDone` and `Item.setRepeat`, and skipping a copy and changing the rule for this one or all upcoming (`RepeatCopies.skip`, `RepeatCopies.change`); `RepeatChoices`, a rule as the repeat form's choices and back, the rule in words, its next dates and its first date, and a rule pinned to a copy's day.
  - `Sync/`: sync with the private iCloud database. `SyncState` tracks each record's server values and pending fields, and settles conflicts field by field; a list that only grows (a review's `stepsDone`, a `SyncField` marked merged) takes what arrives added to what's here, even while its own change waits to be sent. `TasksSync` reads local edits from SwiftData's history and writes what arrives. `CloudKitSyncEngine` runs `CKSyncEngine`, and `CloudKitSchema` codes records. `MemoryServer` stands in for iCloud in tests. `OutsideSaves` notices what the extensions saved, by their author name.

## Licence

The code is under the MIT licence in [LICENSE](LICENSE). The Cecily name, mark and icons aren't: see [NOTICE](NOTICE). The notes editor bundles open-source packages listed, with their copyright lines, in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Issues

Bug reports and ideas are welcome as issues; pull requests aren't accepted. See [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md) for reporting a security problem.
