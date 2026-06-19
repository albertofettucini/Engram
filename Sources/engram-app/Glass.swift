import SwiftUI

extension View {
    /// A dashboard panel. With `matte` it's a flat, opaque, solid-color surface (for people who don't
    /// want the glass). Otherwise it's Liquid Glass that refracts the desktop behind it (real
    /// `.glassEffect` on macOS 26, a material fallback below), with a tunable frost fill.
    ///
    /// IMPORTANT: the look is applied as a STABLE background layer — `self` (the panel's content) is never
    /// wrapped inside a matte-vs-glass `if`/`else`. Flipping the Liquid Glass switch therefore only
    /// cross-fades the opaque matte cover's opacity; it does NOT rebuild the content. (The old branching
    /// version rebuilt every panel on each toggle, which tore down any open popover — e.g. Settings closed
    /// itself the instant you flipped the switch.)
    func liquidPanel(corner: CGFloat = 14, frost: Double = 0.0, matte: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return self
            .background {
                ZStack {
                    // Liquid Glass (or material fallback). `#available` is fixed at runtime, so toggling
                    // matte never switches this branch — only the cover opacity below changes.
                    if #available(macOS 26.0, *) {
                        shape.fill(Color(nsColor: .controlBackgroundColor).opacity(frost * 0.85))   // tunable frost
                            .glassEffect(.clear, in: .rect(cornerRadius: corner))
                    } else {
                        shape.fill(.ultraThinMaterial)
                            .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    }
                    // Opaque matte cover: invisible with glass on, fully opaque with glass off.
                    shape.fill(Color(nsColor: .controlBackgroundColor)).opacity(matte ? 1 : 0)
                }
            }
            .overlay(shape.strokeBorder(.primary.opacity(matte ? 0.08 : 0), lineWidth: 1))   // border only in matte mode
            .shadow(color: .black.opacity(matte ? 0.14 : 0), radius: matte ? 9 : 0, y: matte ? 3 : 0)
    }
}
