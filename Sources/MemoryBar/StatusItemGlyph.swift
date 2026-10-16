import AppKit

/// The Status item component (design-system/DESIGN.md): one SF Symbol from
/// the app-icon family, as a template image at `Control.statusGlyph`, medium
/// weight, so every house item sits on one baseline at one weight. Outline
/// when idle; `.fill` means on; colour only for a state that also has a word.
enum StatusItemGlyph {

    static let configuration = NSImage.SymbolConfiguration(
        pointSize: House.Control.statusGlyph, weight: .medium
    )

    /// The template glyph the menu bar tints itself.
    static func image(_ symbol: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    /// The same glyph painted in one colour, for the one state DESIGN.md
    /// allows to carry `danger` (recording, or a permission fault).
    static func image(_ symbol: String, description: String, tinted color: NSColor) -> NSImage? {
        guard let base = image(symbol, description: description) else { return nil }
        let painted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        painted.isTemplate = false
        painted.accessibilityDescription = description
        return painted
    }

    /// Offscreen proof: the glyph on a menu-bar-like ground in one appearance,
    /// at 4x so the weight and baseline can be read by eye.
    static func proof(_ image: NSImage, appearance: NSAppearance?, scale: CGFloat = 4) -> NSImage {
        let inset = House.Spacing.sm
        let size = NSSize(
            width: (image.size.width + 2 * inset) * scale,
            height: (image.size.height + 2 * inset) * scale
        )
        let proof = NSImage(size: size, flipped: false) { rect in
            House.NSColorToken.surface.setFill()
            rect.fill()
            let target = NSRect(
                x: inset * scale, y: inset * scale,
                width: image.size.width * scale, height: image.size.height * scale
            )
            // What the menu bar does with a template: paint the ink through it.
            let shown = image.isTemplate ? ink(image) : image
            shown.draw(in: target)
            return true
        }
        _ = appearance
        return proof
    }

    /// A template glyph painted in `textPrimary` on a clear ground.
    private static func ink(_ image: NSImage) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            House.NSColorToken.textPrimary.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
