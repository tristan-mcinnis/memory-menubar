import AppKit
import Combine
import Foundation
import MemoryBarCore

/// A one-line answer under the header: what just happened, with a dot.
struct Confirmation: Equatable {
    let ok: Bool
    let text: String
}

/// One labelled group of task rows in the Today glance, already trimmed to
/// the row budget, with the count that did not fit.
struct TodayTaskGroup: Equatable, Identifiable {
    let label: String
    /// The line drawn in place of rows when the section is empty.
    let emptyText: String
    let tasks: [RecallOutput.Task]
    let overflow: Int

    var id: String { label }

    /// What is drawn where rows would go. The empty line is used only when the
    /// section really is empty; a section that had rows but no budget left
    /// says how many there are, because "nothing due today" over two tasks
    /// that did not fit is a lie.
    var placeholder: String {
        overflow > 0 ? "\(overflow) more" : emptyText
    }
}

/// The Today surface laid out once: the health lines, the capture rows, and
/// the three curated sections with their row budget spent.
///
/// Every line here costs a row of the same budget: a note is a line the panel
/// draws, so a busy board cannot push the capture or task rows off the panel.
/// Pure, so the whole layout is tested without a window.
struct TodayPlan: Equatable {
    /// Why there are no capture rows: unreadable, or none today. Nil when the
    /// capture rows are drawn.
    let captureNote: PanelModel.TodayNote?
    /// The unresolved-triage health line, or why it could not be read.
    let triageNote: PanelModel.TodayNote?
    /// The task read's own status: unreadable, or a partial read's reason.
    let taskNote: PanelModel.TodayNote?
    /// How big the whole open backlog is and where it is piled up.
    let backlogNote: PanelModel.TodayNote?
    let captures: [RecallOutput.Capture]
    let captureOverflow: Int
    let groups: [TodayTaskGroup]

    var notes: [PanelModel.TodayNote] {
        [captureNote, triageNote, taskNote, backlogNote].compactMap { $0 }
    }

    /// Every task row the surface draws, in draw order. The selection walks
    /// this list and nothing else: a capture row is not selectable.
    var taskRows: [RecallOutput.Task] { groups.flatMap(\.tasks) }

    /// Where a task sits in the selectable list, or nil when it is not drawn.
    func index(of task: RecallOutput.Task) -> Int? {
        taskRows.firstIndex { $0.id == task.id }
    }
}

/// The panel's live state and every action behind it.
///
/// Memory owns no store and no collector. Every row here is a call to a
/// program that already exists on this Mac: `recall` for the memory verbs,
/// `launchctl` for the collector's launchd job, and `screenctx status` for
/// what the collector is doing. All of those run off the main thread; the
/// panel is never blocked on a subprocess.
@MainActor
final class PanelModel: ObservableObject {

    /// What the panel is showing. The rows are the resting state; the other
    /// three replace them in place and Escape comes back here.
    enum Mode: Equatable {
        case rows
        case capture
        case search
        case today
    }

    // MARK: Published state

    @Published private(set) var snapshot: CollectorSnapshot = .pending
    @Published var mode: Mode = .rows
    @Published var selection: Int = 0
    @Published var confirmation: Confirmation?

    @Published var captureText: String = ""

    @Published var searchQuery: String = ""
    @Published private(set) var hits: [RecallOutput.Hit] = []
    @Published private(set) var isSearching = false
    /// Why there are no result rows, in recall's words or ours. Nil while
    /// there are results to show.
    @Published private(set) var searchNote: String?

    @Published private(set) var today: RecallOutput.Today?
    @Published private(set) var todayNote: String?
    /// The Today surface as it is drawn, so the rows on screen and the list the
    /// keyboard walks are the same object.
    @Published private(set) var todayPlan: TodayPlan?

    // MARK: Collaborators

    private let agent: LaunchAgent
    private let tools: ToolPaths
    private let defaults: UserDefaults
    /// The collector's queue: the poll and the master switch (launchctl and
    /// `screenctx status`).
    private let work = DispatchQueue(label: "com.tristan.memory-menubar.work", qos: .userInitiated)
    /// The recall verbs' queue: Capture, Search and Today. Kept off `work` so
    /// a key pressed right after opening does not wait behind the collector
    /// read that the open itself started; a cold `screenctx status` over the
    /// live store takes about a second. Serial, so recall calls stay in the
    /// order they were asked.
    private let recallWork = DispatchQueue(label: "com.tristan.memory-menubar.recall", qos: .userInitiated)

    private var pollTimer: Timer?
    private var resumeTimer: Timer?
    private var searchWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    /// Bumped on every keystroke so a slow search cannot overwrite a newer one.
    private var searchGeneration = 0
    /// Admission for the poll only: one read in flight, one owed catch-up, so
    /// a slow read never stacks stale reads behind it on the serial queue.
    private var pollGate = PollGate()

    /// When the panel was last opened. Launch counts as an open, so a Mac
    /// that has just started polls at the normal rate until the first idle
    /// threshold passes.
    private var lastOpenedAt = Date()
    /// When the last poll landed, which is how old the words on screen are.
    /// Nil until the first read comes back.
    var lastPolledAt: Date?
    /// The clock, injected so the idle backoff is tested without waiting.
    var now: () -> Date = { Date() }
    /// The read a stale open kicks off behind the panel. It is the ordinary
    /// poll; a test replaces it so that opening a panel runs no CLI.
    lazy var backgroundRefresh: () -> Void = { [weak self] in self?.poll() }

    /// Raised while the panel is on screen, so polling speeds up.
    var isPanelOpen = false { didSet { schedulePoll() } }

    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    var onClose: () -> Void = {}
    /// Fired whenever the snapshot changes, so the status item can repaint.
    var onSnapshotChange: (CollectorSnapshot) -> Void = { _ in }

    /// How long a "pause for an hour" lasts.
    static let pauseDuration: TimeInterval = 60 * 60
    /// The key holding the moment a timed pause ends. Persisted so quitting
    /// Memory during a pause cannot leave the collector off forever.
    static let pauseUntilKey = "pauseUntil"
    static let pollIntervalKey = "pollIntervalSeconds"
    static let debounceSeconds: TimeInterval = 0.25
    /// How many result rows the panel shows, and how many Today rows: the
    /// capture rows, the health lines, and the three curated task sections
    /// together.
    static let resultLimit = 6
    static let todayRowLimit = 8
    /// How much of a CLI's reason line the panel keeps. A partial task read
    /// names every store it could not open, and one of those lists must not
    /// take the panel; the head of the reason is what says what failed.
    nonisolated static let reasonClipLength = 140
    /// How often the panel re-reads the collector while it is open, so the
    /// tick age on screen stays honest.
    static let openPollInterval: TimeInterval = 15
    /// How long the panel can go unopened before the poll starts stretching.
    /// Two hours is longer than a walk away from the desk and shorter than a
    /// morning, so a collector nobody has looked at since breakfast stops
    /// costing three subprocesses a minute.
    static let idleThreshold: TimeInterval = 2 * 60 * 60
    /// The longest gap between polls, however long nobody looks. Half an hour
    /// keeps the backoff bounded: at worst one open finds words half an hour
    /// old and reads again behind the panel.
    static let idlePollCeiling: TimeInterval = 30 * 60
    /// The share of the interval macOS may slide a poll wakeup by, so it can
    /// batch this timer with others instead of waking the CPU for it alone.
    /// A background poll owes nobody a particular second.
    static let pollToleranceFraction = 0.15

    init(
        agent: LaunchAgent = .screenctx,
        tools: ToolPaths = .installed,
        defaults: UserDefaults = .standard
    ) {
        self.agent = agent
        self.tools = tools
        self.defaults = defaults

        $searchQuery
            .dropFirst()
            .sink { [weak self] query in self?.scheduleSearch(query) }
            .store(in: &cancellables)
    }

    // MARK: - Rows

    /// The three memory verbs. "Open screen timeline" is deliberately absent:
    /// the timeline of the collector this panel switches is `screenctx
    /// timeline` in a shell, and the panel has no view of it. screenctx is
    /// the one screen-history collector; Quick Launch's old one is retired.
    var primaryActions: [PanelAction] {
        [
            PanelAction(id: "capture", glyph: "square.and.pencil", title: "Capture a thought", chord: "⌘N") {
                [weak self] in self?.beginCapture()
            },
            PanelAction(id: "search", glyph: "magnifyingglass", title: "Search memory", chord: "⌘F") {
                [weak self] in self?.beginSearch()
            },
            PanelAction(id: "today", glyph: "sun.max", title: "Today", chord: "⌘T") {
                [weak self] in self?.beginToday()
            },
        ]
    }

    /// The rarer group: two ways to look at the collector, and a timed pause.
    var moreActions: [PanelAction] {
        [
            PanelAction(
                id: "pause",
                glyph: "pause.circle",
                title: pauseRowTitle,
                isEnabled: snapshot.isBootstrapped || isTimedPauseRunning,
                isQuiet: true
            ) { [weak self] in self?.togglePauseForAnHour() },
            PanelAction(id: "store", glyph: "folder", title: "Screen-context store", isQuiet: true) {
                [weak self] in self?.revealStoreFolder()
            },
            PanelAction(id: "log", glyph: "doc.plaintext", title: "Collector log", isQuiet: true) {
                [weak self] in self?.openCollectorLog()
            },
        ]
    }

    private var pauseRowTitle: String {
        guard let until = timedPauseEnd else { return "Pause collector for 1 hour" }
        let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
        return "Resume now · \(minutes) min left"
    }

    /// Every row the keyboard walks, in order: the verbs, the rarer group,
    /// then the two footer actions.
    var selectableActions: [PanelAction] {
        primaryActions + moreActions + [
            PanelAction(id: "settings", glyph: "gearshape", title: "Settings", chord: "⌘,") {
                [weak self] in self?.onOpenSettings()
            },
            PanelAction(id: "quit", glyph: "power", title: "Quit", chord: "⌘Q") {
                [weak self] in self?.onQuit()
            },
        ]
    }

    var footerSelectionBase: Int { primaryActions.count + moreActions.count }

    func moveSelection(by delta: Int) {
        switch mode {
        case .rows:
            let rows = selectableActions
            guard !rows.isEmpty else { return }
            var next = selection
            for _ in 0..<rows.count {
                next = (next + delta + rows.count) % rows.count
                if rows[next].isEnabled { break }
            }
            selection = next
        case .search:
            guard !hits.isEmpty else { return }
            selection = (selection + delta + hits.count) % hits.count
        case .today:
            // Only the task rows are selectable; a capture row is a line of
            // text and the health notes are not actioned.
            let tasks = todayPlan?.taskRows ?? []
            guard !tasks.isEmpty else { return }
            selection = (selection + delta + tasks.count) % tasks.count
        case .capture:
            break
        }
    }

    func runSelection() {
        switch mode {
        case .rows:
            let rows = selectableActions
            guard rows.indices.contains(selection), rows[selection].isEnabled else { return }
            rows[selection].run()
        case .capture:
            commitCapture()
        case .search:
            copySelectedHit()
        case .today:
            guard let tasks = todayPlan?.taskRows, tasks.indices.contains(selection) else { return }
            runTaskAction(tasks[selection])
        }
    }

    // MARK: - Modes

    func beginCapture() {
        confirmation = nil
        captureText = ""
        mode = .capture
    }

    func beginSearch() {
        confirmation = nil
        hits = []
        searchNote = nil
        searchQuery = ""
        selection = 0
        mode = .search
    }

    func beginToday() {
        confirmation = nil
        selection = 0
        mode = .today
        reloadToday()
    }

    /// Escape: back out one step, then close. A mode returns to the rows, the
    /// rows close the panel.
    func escape() {
        switch mode {
        case .rows:
            onClose()
        case .capture, .search, .today:
            searchWorkItem?.cancel()
            mode = .rows
            selection = 0
        }
    }

    // MARK: - Capture

    /// Hand one thought to `recall capture` and report exactly what it said.
    func commitCapture() {
        let text = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        captureText = ""
        mode = .rows
        selection = 0
        confirmation = Confirmation(ok: true, text: "Capturing…")

        recallWork.async { [tools] in
            let outcome = RecallOutput.capture(text, tools: tools)
            DispatchQueue.main.async { [weak self] in
                self?.confirmation = Confirmation(ok: outcome.ok, text: outcome.message)
            }
        }
    }

    // MARK: - Search

    /// Run a search a quarter-second after typing stops. Every keystroke
    /// cancels the pending run, and a result that comes back for an older
    /// query is dropped rather than shown.
    private func scheduleSearch(_ query: String) {
        searchWorkItem?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration

        guard !trimmed.isEmpty else {
            hits = []
            searchNote = nil
            isSearching = false
            return
        }

        isSearching = true
        let item = DispatchWorkItem { [tools] in
            let result = RecallOutput.search(trimmed, tools: tools)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchGeneration == generation else { return }
                self.isSearching = false
                switch result {
                case let .success(payload):
                    self.hits = Array(payload.hits.prefix(Self.resultLimit))
                    self.searchNote = payload.hits.isEmpty ? "No hits" : nil
                    self.selection = 0
                case let .failure(error):
                    self.hits = []
                    self.searchNote = error.message
                }
            }
        }
        searchWorkItem = item
        recallWork.asyncAfter(deadline: .now() + Self.debounceSeconds, execute: item)
    }

    /// Return on a result: put its file on the clipboard. The panel copies a
    /// path rather than opening a file, because what a memory hit is for is
    /// pasting into whatever is already open.
    func copySelectedHit() {
        guard hits.indices.contains(selection) else { return }
        let hit = hits[selection]
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hit.absolutePath, forType: .string)
        mode = .rows
        selection = 0
        confirmation = Confirmation(ok: true, text: "Copied \(hit.path)")
    }

    // MARK: - Today

    /// A status line about the task board, and whether it is a failure.
    struct TodayNote: Equatable {
        let text: String
        let danger: Bool
    }

    /// Lay the whole Today surface out: the health lines first, because they
    /// are drawn lines that spend the same row budget, then the capture rows,
    /// then the three curated task sections with what is left. Pure, so the
    /// layout, the wording and the budget are tested without a window.
    static func makeTodayPlan(_ today: RecallOutput.Today, budget: Int) -> TodayPlan {
        // The capture line: why there are no rows, or nothing, when the rows
        // are drawn instead.
        let captureNote: TodayNote?
        if !today.captures.readable {
            captureNote = TodayNote(
                text: clippedReason(today.captures.reason ?? "captures unreadable"), danger: true
            )
        } else if today.captures.items.isEmpty {
            captureNote = TodayNote(text: "no captures today", danger: false)
        } else {
            captureNote = nil
        }

        let triageNote = todayTriageNote(today.triage)
        let taskNote = todayTaskStatusNote(today.tasks)
        let backlogNote = todayBacklogNote(today.tasks)
        let spent = [captureNote, triageNote, taskNote, backlogNote].compactMap { $0 }.count
        var remaining = max(0, budget - spent)

        var captureRows: [RecallOutput.Capture] = []
        if today.captures.readable {
            captureRows = Array(today.captures.items.prefix(min(3, remaining)))
            remaining -= captureRows.count
        }

        return TodayPlan(
            captureNote: captureNote,
            triageNote: triageNote,
            taskNote: taskNote,
            backlogNote: backlogNote,
            captures: captureRows,
            captureOverflow: today.captures.readable ? today.captures.items.count - captureRows.count : 0,
            // An unreadable board draws no sections: three empty sections over
            // a failed read would be exactly the lie the note is there to stop.
            groups: today.tasks.readable ? todayTaskGroups(today.tasks, budget: remaining) : []
        )
    }

    /// Split the day's one row budget across the three curated task sections.
    /// Every non-empty section gets a row before any section spends the
    /// leftover, so a long due-today list cannot hide the overdue one; the
    /// leftover then follows section order. Each group reports what did not
    /// fit rather than dropping it silently. Pure, so the split is tested
    /// without a window.
    static func todayTaskGroups(_ tasks: RecallOutput.TaskSections, budget: Int) -> [TodayTaskGroup] {
        let lists: [(label: String, emptyText: String, items: [RecallOutput.Task])] = [
            ("Due today", "nothing due today", tasks.dueToday),
            ("Overdue", "nothing overdue", tasks.overdue),
            ("In progress", "nothing in progress", tasks.inProgress),
        ]

        var shown = [Int](repeating: 0, count: lists.count)
        var remaining = max(0, budget)
        // One row to each non-empty section first, in section order.
        for index in lists.indices where !lists[index].items.isEmpty && remaining > 0 {
            shown[index] = 1
            remaining -= 1
        }
        // Then the leftover by priority.
        for index in lists.indices {
            let extra = min(lists[index].items.count - shown[index], remaining)
            if extra > 0 {
                shown[index] += extra
                remaining -= extra
            }
        }

        return lists.indices.map { index in
            let items = lists[index].items
            return TodayTaskGroup(
                label: lists[index].label,
                emptyText: lists[index].emptyText,
                tasks: Array(items.prefix(shown[index])),
                overflow: items.count - shown[index]
            )
        }
    }

    /// What to say about the task board under its heading, or nil when there
    /// is nothing to say. A partial read keeps recall's reason quietly; an
    /// unreadable board says it in the danger colour.
    static func todayTaskStatusNote(_ tasks: RecallOutput.TaskSections) -> TodayNote? {
        if !tasks.readable { return TodayNote(text: clippedReason(tasks.reason ?? "tasks unreadable"), danger: true) }
        if let reason = tasks.reason { return TodayNote(text: "tasks: " + clippedReason(reason), danger: false) }
        return nil
    }

    /// How big the whole open backlog is, and where it is piled up, so an
    /// empty day cannot read as an empty board. The two biggest lanes only;
    /// the full list is `recall tasks`. Nil when the board could not be read,
    /// because a count Memory did not get back must never be drawn.
    nonisolated static func todayBacklogNote(_ tasks: RecallOutput.TaskSections) -> TodayNote? {
        guard tasks.readable else { return nil }
        let lanes = tasks.laneCounts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(2)
            .map { "\($0.key) \($0.value)" }
        let laneText = lanes.isEmpty ? "" : " · " + lanes.joined(separator: " · ")
        return TodayNote(text: "\(tasks.openCount) open in the backlog" + laneText, danger: false)
    }

    /// The unresolved-triage health line. Nil on an empty queue, which needs
    /// no line; a queue that could not be read is said in the danger colour
    /// rather than drawn as empty.
    nonisolated static func todayTriageNote(_ triage: RecallOutput.Triage) -> TodayNote? {
        guard triage.readable else {
            return TodayNote(
                text: "triage unreadable: " + clippedReason(triage.reason ?? "no reason reported"),
                danger: true
            )
        }
        guard triage.count > 0 else { return nil }
        var text = "\(triage.count) unresolved " + (triage.count == 1 ? "capture" : "captures")
        if let day = shortDay(triage.oldest) { text += " · oldest \(day)" }
        return TodayNote(text: text, danger: false)
    }

    /// A CLI's reason line, clipped to what fits the panel. Memory changes no
    /// words, only where the line ends, so the head that names the failure is
    /// kept and the tail that lists every store is dropped. The cut lands on a
    /// space once one is past the halfway mark, so a store is not left
    /// half-printed and the line still keeps most of what it had.
    nonisolated static func clippedReason(_ text: String, limit: Int = PanelModel.reasonClipLength) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        if let space = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: space) >= limit / 2 {
            return String(head[head.startIndex..<space]) + "…"
        }
        return String(head) + "…"
    }

    /// The day part of an ISO-8601 stamp, or nil when it is not one. The owner
    /// CLI stamps every capture in one fixed zone, so the string order is the
    /// age order and the first ten characters are the day.
    nonisolated static func shortDay(_ stamp: String) -> String? {
        guard stamp.count >= 10 else { return nil }
        let day = String(stamp.prefix(10))
        let parts = day.split(separator: "-")
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return day
    }

    // MARK: - Task rows

    /// What Return on a task row does.
    enum TaskAction: Equatable {
        /// Open the owning source file with `NSWorkspace`, the same safe
        /// native mechanism the Collector log row uses: a path to an app, no
        /// shell, no interpolation.
        case openSource(String)
        /// Put a paste-ready request on the clipboard instead. Used when the
        /// source is not a file a person can act in, so Return never opens a
        /// dead end.
        case copyRequest(String)
    }

    /// Whether a path names a file a person can open and work in. The vault
    /// backend's source is its project `00-tasks.md`; the memory backend's is
    /// a `tasks.jsonl` record, which is a store, not a document.
    nonisolated static func isOpenableSource(_ path: String) -> Bool {
        guard (path as NSString).pathExtension.lowercased() == "md" else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    /// Open the owning markdown file, or copy a precise request for the task.
    /// Pure apart from the file probe it is handed, so both branches are
    /// tested without touching the disk.
    nonisolated static func taskAction(
        for task: RecallOutput.Task,
        isOpenable: (String) -> Bool = PanelModel.isOpenableSource
    ) -> TaskAction {
        if isOpenable(task.source) { return .openSource(task.source) }
        return .copyRequest(taskRequest(for: task))
    }

    /// The request Return copies: the task's own identity, its owning file and
    /// its lane, so pasting it into Pi needs no follow-up question. Memory
    /// does not write the task store; this is words on a clipboard.
    nonisolated static func taskRequest(for task: RecallOutput.Task) -> String {
        var text = "Take up the task \"\(task.title)\""
        if !task.source.isEmpty { text += " in \(task.source)" }
        var context: [String] = []
        if !task.project.isEmpty { context.append("project \(task.project)") }
        if !task.lane.isEmpty { context.append("lane \(task.lane)") }
        if !task.taskID.isEmpty { context.append("id \(task.taskID)") }
        if !context.isEmpty { text += " (\(context.joined(separator: ", ")))" }
        return text + "."
    }

    /// Return on a selected task row: open its file, or copy the request.
    func runTaskAction(_ task: RecallOutput.Task) {
        switch Self.taskAction(for: task) {
        case let .openSource(path):
            if NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
                onClose()
            } else {
                confirmation = Confirmation(ok: false, text: "Could not open \(task.title)")
            }
        case let .copyRequest(request):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let copied = pasteboard.setString(request, forType: .string)
            mode = .rows
            selection = 0
            confirmation = Confirmation(
                ok: copied,
                text: copied ? "Copied a request for \(task.title)" : "Could not copy \(task.title)"
            )
        }
    }

    func reloadToday() {
        todayNote = nil
        todayPlan = nil
        recallWork.async { [tools] in
            let result = RecallOutput.today(tools: tools)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case let .success(payload):
                    self.today = payload
                    self.todayNote = nil
                    self.todayPlan = Self.makeTodayPlan(payload, budget: Self.todayRowLimit)
                case let .failure(error):
                    self.today = nil
                    self.todayPlan = nil
                    self.todayNote = error.message
                }
            }
        }
    }

    // MARK: - The collector

    /// The master switch: bootstrap the launchd job, or boot it out. Memory
    /// reports what launchctl said and re-reads the state; it never assumes
    /// the switch worked.
    func setCollecting(_ on: Bool) {
        if on { clearTimedPause() }
        confirmation = Confirmation(ok: true, text: on ? "Starting collector…" : "Stopping collector…")
        work.async { [agent, tools] in
            let result = agent.setBootstrapped(on, tools: tools)
            let snapshot = CollectorSnapshot.read(agent: agent, tools: tools)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apply(snapshot)
                if result.succeeded {
                    self.confirmation = Confirmation(ok: true, text: on ? "Collector started" : "Collector stopped")
                } else {
                    let said = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.confirmation = Confirmation(
                        ok: false,
                        text: said.isEmpty ? "launchctl exited \(result.exitCode)" : said
                    )
                }
            }
        }
    }

    var isCollecting: Bool { snapshot.isBootstrapped }

    /// When the running timed pause ends, or nil when there is not one.
    var timedPauseEnd: Date? {
        let stamp = defaults.double(forKey: Self.pauseUntilKey)
        guard stamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: stamp)
        return date > Date() ? date : nil
    }

    var isTimedPauseRunning: Bool { timedPauseEnd != nil }

    /// Pause for an hour, or resume now if a pause is already running. The
    /// deadline is on disk, so the collector comes back even if Memory is
    /// quit in the meantime.
    func togglePauseForAnHour() {
        if isTimedPauseRunning {
            clearTimedPause()
            setCollecting(true)
            return
        }
        defaults.set(Date().addingTimeInterval(Self.pauseDuration).timeIntervalSince1970, forKey: Self.pauseUntilKey)
        scheduleResume()
        setCollecting(false)
        confirmation = Confirmation(ok: true, text: "Paused for 1 hour")
    }

    private func clearTimedPause() {
        defaults.removeObject(forKey: Self.pauseUntilKey)
        resumeTimer?.invalidate()
        resumeTimer = nil
    }

    /// Arm the timer that ends a pause. Called on launch too, so a pause that
    /// outlived the app still ends.
    func scheduleResume() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        guard let end = timedPauseEnd else {
            // The deadline has passed. If the collector is still off because
            // of it, bring it back.
            if defaults.double(forKey: Self.pauseUntilKey) > 0 {
                defaults.removeObject(forKey: Self.pauseUntilKey)
                setCollecting(true)
            }
            return
        }
        let timer = Timer(fire: end, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.clearTimedPause()
                self?.setCollecting(true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resumeTimer = timer
    }

    // MARK: - Reveal

    /// Reveal the collector's store in Finder. User-initiated, so taking the
    /// foreground is what was asked for.
    func revealStoreFolder() {
        let path = snapshot.storeFolder ?? (NSHomeDirectory() + "/Library/Application Support/screenctx")
        onClose()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// Open the launchd job's log, at the path the plist declares.
    func openCollectorLog() {
        guard let log = agent.definition()?.logPath else {
            confirmation = Confirmation(ok: false, text: "no log path in \(agent.plistPath)")
            return
        }
        guard FileManager.default.fileExists(atPath: log) else {
            confirmation = Confirmation(ok: false, text: "no log file at \(log)")
            return
        }
        onClose()
        NSWorkspace.shared.open(URL(fileURLWithPath: log))
    }

    // MARK: - Polling

    /// Seconds between polls while the panel is in use, from settings.
    var baseInterval: TimeInterval {
        let configured = defaults.double(forKey: Self.pollIntervalKey)
        return configured > 0 ? configured : 60
    }

    /// Seconds between polls now: fast while the panel is open so the tick age
    /// stays honest, the configured interval while it is closed, and a longer
    /// one once nobody has opened it for hours.
    var pollInterval: TimeInterval {
        if isPanelOpen { return Self.openPollInterval }
        return Self.backedOffInterval(base: baseInterval, idleFor: idleDuration)
    }

    /// How long since the panel was last opened.
    private var idleDuration: TimeInterval { max(0, now().timeIntervalSince(lastOpenedAt)) }

    /// The interval to poll at, given the configured interval and how long the
    /// panel has gone unopened. Under the threshold it is the configured
    /// interval; past it the gap doubles for every further threshold, up to the
    /// ceiling. A configured interval longer than the ceiling is the user's
    /// choice and is never shortened. Pure, so the decision is tested without a
    /// clock.
    static func backedOffInterval(base: TimeInterval, idleFor: TimeInterval) -> TimeInterval {
        guard idleFor >= idleThreshold else { return base }
        // Eight doublings pass any ceiling; the cap keeps the exponent small.
        let steps = min(Int(idleFor / idleThreshold), 8)
        return max(base, min(base * pow(2, Double(steps)), idlePollCeiling))
    }

    /// Whether what is on screen is older than one normal poll. An unpolled
    /// panel counts as stale: there is nothing on screen to trust yet.
    static func isStale(age: TimeInterval?, base: TimeInterval) -> Bool {
        guard let age else { return true }
        return age > base
    }

    /// How old the words on screen are, by the time the last poll landed.
    private var snapshotAge: TimeInterval? {
        lastPolledAt.map { now().timeIntervalSince($0) }
    }

    /// What the armed poll timer is set to, for tests. Nil when none is armed.
    var scheduledPoll: (interval: TimeInterval, tolerance: TimeInterval)? {
        pollTimer.map { ($0.timeInterval, $0.tolerance) }
    }

    func start() {
        scheduleResume()
        poll()
        schedulePoll()
    }

    func schedulePoll() {
        pollTimer?.invalidate()
        let interval = pollInterval
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.poll() }
        }
        // Let macOS batch this wakeup with whatever else wakes near it rather
        // than waking the CPU for the poll alone.
        timer.tolerance = interval * Self.pollToleranceFraction
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Called when the panel opens. Opening draws the words already in hand at
    /// once and waits on no read. It ends any idle backoff, so the cadence is
    /// back to normal from here, and when what is on screen is older than one
    /// poll it starts a read behind the panel rather than letting an aged tick
    /// age pass for a fresh one.
    func panelOpened() {
        lastOpenedAt = now()
        isPanelOpen = true
        // A confirmation is about the moment it finished. Reopening the panel
        // starts a new moment, so the old one goes rather than sitting under
        // the rows as if it had just happened.
        confirmation = nil
        if Self.isStale(age: snapshotAge, base: baseInterval) { backgroundRefresh() }
    }

    /// One reading, off the main thread. Single-flight: while one read is in
    /// flight a tick is coalesced into one bounded catch-up rather than queued,
    /// so a slow read never builds a backlog. Every admitted read still lands:
    /// `apply` reports the snapshot (deduping an unchanged one), then the gate
    /// is cleared unconditionally and a coalesced tick runs as one fresh read.
    func poll() {
        guard pollGate.requestRead() else { return }
        work.async { [agent, tools] in
            let snapshot = CollectorSnapshot.read(agent: agent, tools: tools)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastPolledAt = self.now()
                self.apply(snapshot)
                if self.pollGate.completeRead() {
                    self.poll()
                }
            }
        }
    }

    private func apply(_ snapshot: CollectorSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        onSnapshotChange(snapshot)
    }

    // MARK: - Render proof

    /// Used by the render proof to draw a state without running anything. The
    /// proof must be identical on any Mac, so it sets the state directly
    /// instead of polling a collector that may or may not be installed.
    func override(snapshot: CollectorSnapshot) {
        self.snapshot = snapshot
    }

    func override(hits: [RecallOutput.Hit]) {
        self.hits = hits
        self.searchNote = hits.isEmpty ? "No hits" : nil
        self.isSearching = false
    }

    func override(today: RecallOutput.Today) {
        self.today = today
        self.todayNote = nil
        self.todayPlan = Self.makeTodayPlan(today, budget: Self.todayRowLimit)
    }
}
