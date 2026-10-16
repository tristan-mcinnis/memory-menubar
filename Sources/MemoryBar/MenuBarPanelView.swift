import AppKit
import SwiftUI
import MemoryBarCore

// The menu-bar surface, following the "Menu bar panel" component in
// design-system/DESIGN.md: a 300 px glass panel in place of an NSMenu, a header
// with a status dot and the one master switch, 36 px action rows with outlined
// key caps, a second group for the rarer actions, and a footer well. The row,
// note and window plumbing is the shared kit in MenuBarPanel.swift.
//
// What is different here: three of the rows open a surface inside the panel
// instead of firing and closing. Capture and Search become a field in place of
// the rows, and Today becomes the glance. Escape backs out one step.

/// A two-line result row: a `label` title over `meta` detail. Used by search
/// hits and by the Today glance, which have the same shape.
struct PanelResultRow: View {
    let title: String
    let detail: String
    var isSelected: Bool = false
    var onHover: () -> Void = {}
    var onTap: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    // The path is the long half and its tail names the file,
                    // so it is cut from the middle rather than the end.
                    .truncationMode(.middle)
            }
            .padding(.horizontal, House.Spacing.sm)
            .padding(.vertical, House.Spacing.xxs)
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: House.Radius.row, style: .continuous)
        if isSelected {
            shape
                .fill(House.ColorToken.selectionFill)
                .overlay(shape.strokeBorder(House.ColorToken.selectionRing, lineWidth: House.hairline))
                .houseShadow(House.Shadow.selection, dark: scheme == .dark)
        } else {
            shape.fill(Color.clear)
        }
    }
}

/// A two-line row that is text, not a control. A capture is something to
/// read; drawing it as a button would hand the keyboard a row with nothing
/// behind it.
struct PanelStaticRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, House.Spacing.sm)
        .padding(.vertical, House.Spacing.xxs)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The inline field the capture and search rows turn into: a leading glyph, a
/// plain text field, and an `esc` cap on the right.
struct PanelField: View {
    let glyph: String
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: glyph)
                .font(.system(size: House.TypeToken.Size.bodySmall))
                .foregroundStyle(House.ColorToken.textTertiary)
                .frame(width: 16)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(House.TypeToken.body)
                .foregroundStyle(House.ColorToken.textPrimary)
                .onSubmit(onSubmit)
            KeyCap(label: "esc")
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(height: House.Control.chip + House.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .fill(House.ColorToken.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .strokeBorder(House.ColorToken.strokeStrong, lineWidth: House.hairline)
        )
    }
}

// MARK: - The panel

struct MenuBarPanelView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var fieldFocused: Bool

    /// The panel width from the mockup.
    static let width: CGFloat = 300

    var body: some View {
        HouseGlass(radius: House.Radius.lg) {
            VStack(spacing: 0) {
                header
                SlateDivider()
                body(for: model.mode)
                FooterWell(height: 36) {
                    footerButton(
                        index: model.footerSelectionBase,
                        title: "Settings", chord: "⌘ ,", run: model.onOpenSettings
                    )
                } trailing: {
                    footerButton(
                        index: model.footerSelectionBase + 1,
                        title: "Quit", chord: "⌘ Q", run: model.onQuit
                    )
                }
            }
        }
        .frame(width: Self.width)
        .padding(House.Spacing.md)
        .onChange(of: model.mode) { _, mode in
            fieldFocused = (mode == .capture || mode == .search)
        }
    }

    // MARK: Header

    /// 26 px icon tile, the app name in `label`, a status line in `caption`
    /// with a 6 px dot, and the ink toggle for the one master switch.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: House.Spacing.sm) {
                IconTile(symbol: "bookmark")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Memory")
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                    HStack(spacing: House.Spacing.xxs) {
                        StatusDot(tint: dotTint)
                        Text(model.snapshot.headline)
                            .font(House.TypeToken.caption)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: House.Spacing.xs)
                InkSwitch(isOn: Binding(
                    get: { model.isCollecting },
                    set: { model.setCollecting($0) }
                ))
                .accessibilityLabel("Collect screen context")
            }
            // The rest of what screenctx said: when the last tick landed and
            // what was in front. It does not fit beside the dot at 300 px, so
            // it sits under the header on its own dim line.
            if let context = model.snapshot.context {
                Text(context)
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .padding(.leading, House.Control.tile + House.Spacing.sm)
            }
        }
        .padding(.horizontal, House.Spacing.sm)
        .padding(.vertical, House.Spacing.sm)
    }

    private var dotTint: Color {
        switch model.snapshot.health {
        case .collecting: return House.ColorToken.success
        case .paused, .permission, .stopped: return House.ColorToken.danger
        case .unknown: return House.ColorToken.textTertiary
        }
    }

    // MARK: Body

    @ViewBuilder
    private func body(for mode: PanelModel.Mode) -> some View {
        VStack(spacing: 2) {
            if let confirmation = model.confirmation, mode == .rows {
                HStack(spacing: House.Spacing.xs) {
                    StatusDot(tint: confirmation.ok ? House.ColorToken.success : House.ColorToken.danger)
                    Text(confirmation.text)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, House.Spacing.sm)
                .padding(.top, House.Spacing.xxs)
            }

            switch mode {
            case .rows:
                rows
            case .capture:
                captureSurface
            case .search:
                searchSurface
            case .today:
                todaySurface
            }
        }
        .padding(.horizontal, House.Spacing.xs)
        .padding(.vertical, House.Spacing.xs)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(Array(model.primaryActions.enumerated()), id: \.element.id) { index, action in
                row(action, index: index)
            }
            SlateDivider().padding(.vertical, House.Spacing.xxs)
            ForEach(Array(model.moreActions.enumerated()), id: \.element.id) { index, action in
                row(action, index: model.primaryActions.count + index)
            }
        }
    }

    private func row(_ action: PanelAction, index: Int) -> some View {
        PanelRow(
            action: action,
            isSelected: model.selection == index,
            onHover: { model.selection = index },
            onTap: action.run
        )
    }

    // MARK: Capture

    private var captureSurface: some View {
        VStack(spacing: 2) {
            PanelField(
                glyph: "square.and.pencil",
                prompt: "Capture a thought",
                text: $model.captureText,
                onSubmit: model.commitCapture
            )
            .focused($fieldFocused)
            .padding(.horizontal, House.Spacing.xxs)
            PanelNote(text: "Return captures it into ~/notes triage. Escape cancels.")
        }
        .padding(.vertical, House.Spacing.xxs)
    }

    // MARK: Search

    private var searchSurface: some View {
        VStack(spacing: 2) {
            PanelField(
                glyph: "magnifyingglass",
                prompt: "Search memory",
                text: $model.searchQuery
            )
            .focused($fieldFocused)
            .padding(.horizontal, House.Spacing.xxs)

            if let note = model.searchNote {
                PanelNote(text: note, danger: !note.hasPrefix("No hits"))
            } else if model.hits.isEmpty {
                PanelNote(text: model.isSearching ? "Searching…" : "Type to search; Return copies the file path.")
            } else {
                ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                    PanelResultRow(
                        title: hit.line,
                        detail: hit.detail,
                        isSelected: model.selection == index,
                        onHover: { model.selection = index },
                        onTap: {
                            model.selection = index
                            model.copySelectedHit()
                        }
                    )
                }
            }
        }
        .padding(.vertical, House.Spacing.xxs)
    }

    // MARK: Today

    /// The `recall today` glance, on the panel's row grid. Eight rows is the
    /// whole budget: the health lines (triage, a partial task read, the open
    /// backlog) and the captures take from it first, and the three curated
    /// task sections (due today, overdue, in progress) share what is left,
    /// each section saying how many more there are. Every non-empty section
    /// stays visible before any section spends the leftover. Capture rows are
    /// read-only; task rows are selectable and Return opens the owning file or
    /// copies a request.
    private var todaySurface: some View {
        VStack(spacing: 2) {
            if let note = model.todayNote {
                PanelNote(text: note, danger: true)
            } else if let plan = model.todayPlan {
                PanelSectionLabel(text: "Today")
                captureLines(plan)
                if let note = plan.triageNote {
                    PanelNote(text: note.text, danger: note.danger)
                }
                if let note = plan.taskNote {
                    PanelNote(text: note.text, danger: note.danger)
                }
                if let note = plan.backlogNote {
                    PanelNote(text: note.text, danger: note.danger)
                }
                ForEach(plan.groups) { group in
                    PanelSectionLabel(text: group.label)
                    if group.tasks.isEmpty {
                        PanelNote(text: group.placeholder)
                    } else {
                        ForEach(group.tasks) { task in
                            let index = plan.index(of: task)
                            PanelResultRow(
                                title: task.title,
                                detail: task.detail,
                                isSelected: index == model.selection,
                                onHover: { if let index { model.selection = index } },
                                onTap: {
                                    guard let index else { return }
                                    model.selection = index
                                    model.runSelection()
                                }
                            )
                        }
                        if group.overflow > 0 {
                            PanelNote(text: "\(group.overflow) more")
                        }
                    }
                }
            } else {
                PanelNote(text: "Reading today…")
            }
        }
        .padding(.vertical, House.Spacing.xxs)
    }

    /// Today's captures, as read-only lines. A capture that did not fit says
    /// how many more there are rather than being dropped silently, and an
    /// empty or unreadable read says which one it is.
    @ViewBuilder
    private func captureLines(_ plan: TodayPlan) -> some View {
        if !plan.captures.isEmpty {
            ForEach(plan.captures) { capture in
                PanelStaticRow(
                    title: capture.text,
                    detail: [capture.kind, capture.time].filter { !$0.isEmpty }.joined(separator: " · ")
                )
            }
            if plan.captureOverflow > 0 {
                PanelNote(text: "\(plan.captureOverflow) more")
            }
        } else if plan.captureOverflow > 0 {
            PanelNote(text: "\(plan.captureOverflow) more captures")
        } else if let note = plan.captureNote {
            PanelNote(text: note.text, danger: note.danger)
        }
    }

    // MARK: Footer

    private func footerButton(index: Int, title: String, chord: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            KeyHint(title: title, chord: chord)
                .padding(.horizontal, House.Spacing.xxs)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .fill(
                            model.mode == .rows && model.selection == index
                                ? House.ColorToken.selectionFill
                                : Color.clear
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0, model.mode == .rows { model.selection = index } }
    }
}
