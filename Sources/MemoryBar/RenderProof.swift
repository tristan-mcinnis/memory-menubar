import AppKit
import SwiftUI
import MemoryBarCore

// Offscreen render proof. `memory-bar --render-proof <dir>` draws every Slate
// surface into PNGs without putting a window on screen, so the design can be
// compared against design-system/DESIGN.md and against Cotype's panel by hand
// or in CI. Nothing here runs in the normal app path, and nothing here runs a
// subprocess: every state is a fixed snapshot, so the proof is the same on any
// Mac. Ported from cotype/Sources/CotypeMenuApp/RenderProof.swift.

@MainActor
enum RenderProof {

    /// Render every proof surface into `directory` and return the file paths.
    @discardableResult
    static func run(into directory: URL) -> [URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [URL] = []
        for (name, appearance) in [("dark", NSAppearance(named: .darkAqua)), ("light", NSAppearance(named: .aqua))] {
            let panels: [(String, PanelModel)] = [
                ("panel-collecting", collectingModel()),
                ("panel-capture", captureModel()),
                ("panel-search", searchModel()),
                ("panel-today", todayModel()),
                ("panel-today-empty", todayEmptyModel()),
                ("panel-today-partial", todayPartialModel()),
                ("panel-paused", pausedModel()),
                ("panel-permission", permissionModel()),
            ]
            for (surface, model) in panels {
                if let url = write(
                    view: MenuBarPanelView(model: model),
                    size: NSSize(width: MenuBarPanelView.width + 2 * House.Spacing.md, height: 360),
                    appearance: appearance,
                    to: directory.appendingPathComponent("\(surface)-\(name).png"),
                    fitToContent: true
                ) {
                    written.append(url)
                }
            }
            // Status item: the glyph the menu bar shows, idle and in the one
            // coloured state, over the surface ink of this appearance.
            let glyphs: [(String, NSImage?)] = [
                ("status-item-idle", StatusItemGlyph.image("bookmark", description: "Memory")),
                ("status-item-paused", StatusItemGlyph.image("bookmark.slash", description: "Memory — paused")),
                ("status-item-permission", StatusItemGlyph.image(
                    "bookmark", description: "Memory — permission", tinted: House.NSColorToken.danger)),
            ]
            for (surface, glyph) in glyphs {
                guard let glyph else { continue }
                let url = directory.appendingPathComponent("\(surface)-\(name).png")
                let proof = StatusItemGlyph.proof(glyph, appearance: appearance)
                if writePNG(proof, appearance: appearance, to: url) { written.append(url) }
            }
            if let url = write(
                view: SettingsView(model: collectingModel()),
                size: NSSize(width: 760, height: 660),
                appearance: appearance,
                to: directory.appendingPathComponent("settings-\(name).png")
            ) {
                written.append(url)
            }
        }
        return written
    }

    // MARK: - The states

    private static let collecting = CollectorSnapshot(
        health: .collecting,
        headline: "Collecting · 1,167 frames",
        context: "153.0 MB · last tick just now · Quick Launch",
        isBootstrapped: true,
        storePath: "/home/example/Library/Application Support/screenctx/context.sqlite3"
    )

    private static func model(_ snapshot: CollectorSnapshot) -> PanelModel {
        let model = PanelModel()
        model.override(snapshot: snapshot)
        return model
    }

    static func collectingModel() -> PanelModel {
        let model = model(collecting)
        model.selection = 0
        return model
    }

    static func pausedModel() -> PanelModel {
        model(CollectorSnapshot(
            health: .paused,
            headline: "Paused",
            context: "collector job is not loaded",
            isBootstrapped: false
        ))
    }

    static func permissionModel() -> PanelModel {
        model(CollectorSnapshot(
            health: .permission,
            headline: "Screen Recording missing",
            context: "text capture continues; frames and OCR wait",
            isBootstrapped: true
        ))
    }

    static func captureModel() -> PanelModel {
        let model = model(collecting)
        model.mode = .capture
        model.captureText = "Slate is the house direction"
        return model
    }

    static func searchModel() -> PanelModel {
        let model = model(collecting)
        model.mode = .search
        model.searchQuery = "design system"
        model.override(hits: RenderProof.hits)
        model.selection = 0
        return model
    }

    static func todayModel() -> PanelModel {
        let model = model(collecting)
        model.mode = .today
        model.override(today: RenderProof.today)
        return model
    }

    /// The partial read: the board answered, and the owner CLI named every
    /// registered store it could not open. The panel must clip the reason
    /// rather than grow to fit it.
    static func todayPartialModel() -> PanelModel {
        let model = model(collecting)
        model.mode = .today
        model.override(today: RenderProof.todayPartial)
        return model
    }

    /// The empty day over a full board: nothing due, nothing overdue, nothing
    /// in progress, and the backlog line that says the day is empty and the
    /// board is not.
    static func todayEmptyModel() -> PanelModel {
        let model = model(collecting)
        model.mode = .today
        model.override(today: RenderProof.todayEmpty)
        return model
    }

    // MARK: - Sample payloads

    /// Both sample payloads are decoded from the JSON recall prints rather
    /// than constructed in Swift, so the proof draws what the app would
    /// actually get back and cannot drift from the contract.
    private static let hits: [RecallOutput.Hit] = {
        let json = """
        {"count":3,"file_count":3692,"query":"design system","rank_ms":121,"scan_ms":193,
         "schema_version":1,"hits":[
          {"absolute_path":"/home/example/notes/state/decisions/dec-house-design.md",
           "day":"2026-09-03","line":"The team chose Slate after seeing both directions rendered",
           "line_number":17,"path":"state/decisions/dec-example-design-direction.md","score":6},
          {"absolute_path":"/home/example/notes/inbox/2026-09-03.md",
           "day":"2026-09-03","line":"the design system keeps every color in one file",
           "line_number":3,"path":"inbox/2026-09-03.md","score":4},
          {"absolute_path":"/home/example/notes/reference/design-notes.md",
           "day":"2026-09-01","line":"apps consume the generated token file and never retype a value",
           "line_number":42,"path":"reference/design-notes.md","score":4}]}
        """
        return (try! JSONDecoder().decode(RecallOutput.SearchResult.self, from: Data(json.utf8))).hits
    }()

    private static let today: RecallOutput.Today = {
        let json = """
        {"captures":{"items":[
          {"kind":"note","text":"Slate is the house direction; dark is the default","time":"09:15"},
          {"kind":"","text":"screenctx frame budget looks right at 5 s","time":"14:02"}],
          "readable":true},
         "schema_version":3,
         "tasks":{"due_today":[
          {"backend":"vault","due":"2026-09-16","id":"fixture-task-one-2026-09-16","lane":"captured","project":"alpha","source":"/home/example/notes/projects/alpha/00-tasks.md","title":"Fixture task one"},
          {"backend":"vault","due":"2026-09-16","id":"fixture-task-two-2026-09-16","lane":"captured","project":"alpha","source":"/home/example/notes/projects/alpha/00-tasks.md","title":"Fixture task two"}],
          "in_progress":[
          {"backend":"vault","due":"","id":"fixture-task-three","lane":"in_progress","project":"beta","source":"/home/example/notes/projects/beta/00-tasks.md","title":"Fixture task three"},
          {"backend":"vault","due":"","id":"fixture-task-four","lane":"in_progress","project":"beta","source":"/home/example/notes/projects/beta/00-tasks.md","title":"Fixture task four"},
          {"backend":"vault","due":"2026-09-20","id":"fixture-task-five","lane":"in_progress","project":"gamma","source":"/home/example/notes/projects/gamma/00-tasks.md","title":"Fixture task five"}],
          "overdue":[
          {"backend":"vault","due":"2026-09-04","id":"fixture-task-six","lane":"requires_action","project":"delta","source":"/home/example/notes/projects/delta/00-tasks.md","title":"Fixture task six"},
          {"backend":"memory","due":"2026-09-10","id":"3f2a8c11-0b44-4e2f-9c3a-1d2e3f4a5b6c","lane":"requires_action","project":"delta","source":"/home/example/notes/projects/delta/tasks.jsonl","title":"Fixture task seven"}],
          "lane_counts":{"captured":9,"for_review":2,"in_progress":6,"needs_tristan":1,"requires_action":17,"requires_decision":3,"requires_triage":4},
          "open_count":42,
          "readable":true},
         "triage":{"count":1,"oldest":"2026-09-02T15:14:08+08:00","readable":true}}
        """
        // The proof is a fixed picture; a payload that will not decode is a
        // bug in this file, not a runtime condition, so it fails loudly.
        return try! JSONDecoder().decode(RecallOutput.Today.self, from: Data(json.utf8))
    }()

    /// The empty day. The board summary is a sample (42 open);
    /// the three day sections are empty on purpose, to prove an empty day cannot read as an empty board.
    private static let todayEmpty: RecallOutput.Today = {
        let json = """
        {"captures":{"items":[],"readable":true},
         "schema_version":3,
         "tasks":{"due_today":[],"in_progress":[],
          "lane_counts":{"captured":9,"for_review":2,"in_progress":6,"needs_tristan":1,"requires_action":17,"requires_decision":3,"requires_triage":4},
          "open_count":42,
          "overdue":[],"readable":true},
         "triage":{"count":1,"oldest":"2026-09-02T15:14:08+08:00","readable":true}}
        """
        return try! JSONDecoder().decode(RecallOutput.Today.self, from: Data(json.utf8))
    }()

    /// The partial read. The reason is a sample (8 registered stores the
    /// owner CLI could not open); the panel clips it, so
    /// one list cannot take the whole surface.
    private static let todayPartial: RecallOutput.Today = {
        let json = """
        {"captures":{"items":[],"readable":true},
         "schema_version":3,
         "tasks":{"due_today":[],"in_progress":[
          {"backend":"vault","due":"","id":"fixture-task-three","lane":"in_progress","project":"beta","source":"/home/example/notes/projects/beta/00-tasks.md","title":"Fixture task three"}],
          "lane_counts":{"captured":9,"for_review":2,"in_progress":6,"needs_tristan":1,"requires_action":17,"requires_decision":3,"requires_triage":4},
          "open_count":42,
          "overdue":[],
          "readable":true,
          "reason":"8 registered task stores unreadable: store-one (missing-path), store-two (missing-path), store-three (missing-path), store-four (missing-path), store-five (missing-path), store-six (missing-path), screenctx (missing-path), store-eight (missing-path)"},
         "triage":{"count":0,"oldest":"","readable":true}}
        """
        return try! JSONDecoder().decode(RecallOutput.Today.self, from: Data(json.utf8))
    }()

    // MARK: - Rendering

    /// Encode a ready NSImage as PNG, resolving its drawing in `appearance`.
    private static func writePNG(_ image: NSImage, appearance: NSAppearance?, to url: URL) -> Bool {
        var ok = false
        let body = {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            ok = (try? png.write(to: url)) != nil
        }
        if let appearance { appearance.performAsCurrentDrawingAppearance(body) } else { body() }
        return ok
    }

    private static func write<V: View>(
        view: V,
        size: NSSize,
        appearance: NSAppearance?,
        to url: URL,
        fitToContent: Bool = false
    ) -> URL? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: size)
        if fitToContent {
            let fitted = hosting.fittingSize
            hosting.frame = NSRect(
                origin: .zero,
                size: NSSize(width: max(fitted.width, size.width), height: max(fitted.height, 1))
            )
        }
        hosting.layoutSubtreeIfNeeded()
        // Give SwiftUI one runloop turn to commit its first layout pass.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()
        return capture(hosting, appearance: appearance, to: url)
    }

    /// Snapshot a view over a plain ground, so a glass panel reads the way it
    /// does on screen instead of over transparency.
    private static func capture(_ view: NSView, appearance: NSAppearance?, to url: URL) -> URL? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)

        let scale = rep.pixelsWide > 0 ? CGFloat(rep.pixelsWide) / view.bounds.width : 1
        guard let composite = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: rep.pixelsWide,
            pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composite)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        let isDark = (appearance ?? NSAppearance.currentDrawing())
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            (isDark ? NSColor(white: 0.09, alpha: 1) : NSColor(white: 0.86, alpha: 1)).setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        NSImage(size: view.bounds.size, flipped: false) { rect in
            rep.draw(in: rect)
            return true
        }.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = composite.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: url)
        return url
    }
}
