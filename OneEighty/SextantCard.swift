//
//  SextantCard.swift
//  OneEighty
//
//  A quiet, persistent awareness card pointing to Sextant Run (sextant.run),
//  the run-analysis companion. Cross-promo: people using a running-cadence
//  metronome are structured runners, which is Sextant's beachhead audience.
//
//  The card is styled as a self-contained dark "billboard" using Sextant's own
//  brand tokens and logomark, so it presents Sextant's real identity inside the
//  host app. Token values and the mark geometry are vendored (scoped, minimal)
//  from the brand source of truth: running-app-backend `logos/` (BRAND.md,
//  SextantTokens.swift, logomark-small.svg). Keep them in sync if the brand moves.
//

import SwiftUI
import CoreText
import os

private let logger = Logger(subsystem: "app.rekuro.OneEighty", category: "SextantCard")

// MARK: - Brand fonts (bundled, registered at runtime)
// IBM Plex Mono (wordmark / engraved labels) + Hanken Grotesk (UI text), both
// SIL OFL. Registered process-wide on first use so no Info.plist entry is
// needed. Font.custom falls back to the system font if registration ever fails.

private let sextantFontsRegistered: Bool = {
    for name in ["IBMPlexMono-Medium", "HankenGrotesk-Regular", "HankenGrotesk-SemiBold"] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
            logger.error("Sextant font missing from bundle: \(name, privacy: .public)")
            continue
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            logger.error("Failed to register Sextant font \(name, privacy: .public)")
        }
    }
    return true
}()

private enum SextantFont {
    // Custom fonts anchored to the iOS text-style ramp (relativeTo:) so they
    // scale with Dynamic Type instead of being frozen at a point size.
    static var overline: Font { .custom("IBMPlexMono-Medium", size: 11, relativeTo: .caption2) }
    static var title: Font { .custom("HankenGrotesk-SemiBold", size: 17, relativeTo: .headline) }
    static var lede: Font { .custom("HankenGrotesk-Regular", size: 14, relativeTo: .subheadline) }
}

// MARK: - Brand tokens (scoped, vendored from logos/SextantTokens.swift)
// Sextant leads dark; these are the dark-theme values so the card always shows
// Sextant's signature night identity regardless of the host app's appearance.

private extension Color {
    init(sxHex hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Theme-adaptive color, resolved per trait at render time (mirrors the
    /// dark/light token pairs in the brand's SextantTokens.swift).
    static func sxDynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .light
                ? UIColor(Color(sxHex: light))
                : UIColor(Color(sxHex: dark))
        })
    }
}

// Card follows the host theme: Sextant's ink night identity on a dark host,
// its warm parchment "day" counterpart on a light host. A raised surface,
// border, and soft shadow keep it separated from the host background either way.
private enum Sextant {
    static let cardTop    = Color.sxDynamic(dark: 0x172A35, light: 0xFFFFFF) // raised
    static let cardBottom = Color.sxDynamic(dark: 0x0F1B26, light: 0xFBF7EE)
    static let border     = Color.sxDynamic(dark: 0x27414F, light: 0xE4DCC9)
    static let text       = Color.sxDynamic(dark: 0xF1ECE0, light: 0x0A131C) // bone / ink
    static let textMuted  = Color.sxDynamic(dark: 0x9AA7B4, light: 0x4B5A66)
    static let gold       = Color.sxDynamic(dark: 0xEBB85E, light: 0xB07F2C) // accent — earned moments only
    static let shadow     = Color.sxDynamic(dark: 0x000000, light: 0x1A2530)

    // The signature "ascent" ramp: coral effort warming into gold light. Reads
    // on both themes, so it stays fixed.
    static let ascent = [Color(sxHex: 0xE0573F), Color(sxHex: 0xEC8A52),
                         Color(sxHex: 0xF3BC63), Color(sxHex: 0xF8E2A6)]

    static let radius: CGFloat = 12 // harmonized with the START button
}

// MARK: - Copy & destination

/// Copy and destination for the Sextant cross-promo card. Kept as constants so
/// the UTM attribution tags and the lede cannot silently drift out from under
/// the analytics or the brand voice.
enum SextantPromo {
    static let title = "Sextant: Run Analysis"
    static let lede = "ChatGPT for your runs, without the slop."

    /// An https universal link: it opens the Sextant app directly once deep
    /// links are live, and otherwise falls back to the web with the UTM params
    /// intact for PostHog attribution.
    static let url = URL(string:
        "https://sextant.run/?utm_source=oneeighty&utm_medium=cross-promo&utm_campaign=home-card"
    )!
}

// MARK: - The logomark

/// The Sextant mark, small-glyph form: a two-rep interval HR trace settling onto
/// a goal waypoint. Trace stroked with the ascent gradient; the goal dot is gold
/// (the earned/target color). Drawn natively so it stays crisp at any size.
/// Geometry mirrors `logos/logomark-small.svg` (viewBox 0 0 66 40).
private struct SextantMark: View {
    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 66, sy = size.height / 40
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

            var trace = Path()
            trace.move(to: p(5, 30))
            trace.addLine(to: p(11, 30))
            trace.addCurve(to: p(19, 12), control1: p(14, 30), control2: p(15, 12))
            trace.addLine(to: p(25, 12))
            trace.addCurve(to: p(33, 28), control1: p(28, 12), control2: p(29, 28))
            trace.addLine(to: p(39, 28))
            trace.addCurve(to: p(47, 12), control1: p(42, 28), control2: p(43, 12))
            trace.addLine(to: p(51, 12))

            ctx.stroke(
                trace,
                with: .linearGradient(
                    Gradient(colors: Sextant.ascent),
                    startPoint: p(28, 40), endPoint: p(28, 0) // effort (low) warms up into light
                ),
                style: StrokeStyle(lineWidth: 5 * min(sx, sy), lineCap: .round, lineJoin: .round)
            )

            // Goal waypoint — a sighted dot, gold. Never a star.
            let c = p(59, 12), r = 3 * min(sx, sy)
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: .color(Sextant.gold)
            )
        }
        .frame(width: 34, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - The card

/// A low-key, always-present card at the top of the main screen that follows the
/// host theme. Its job is awareness, not conversion: it reads like a sister-app
/// shelf, not a banner. Tapping opens Sextant.
struct SextantCard: View {
    @Environment(\.openURL) private var openURL

    init() {
        _ = sextantFontsRegistered // register bundled brand fonts before first render
    }

    var body: some View {
        Button {
            logger.info("Sextant card tapped, opening \(SextantPromo.url.absoluteString, privacy: .public)")
            openURL(SextantPromo.url)
        } label: {
            HStack(spacing: 12) {
                SextantMark()

                VStack(alignment: .leading, spacing: 3) {
                    // Engraved mono overline: the locked brand tagline.
                    Text("SEE PAST THE AVERAGES")
                        .font(SextantFont.overline)
                        .tracking(1.4)
                        .foregroundStyle(Sextant.textMuted)
                    Text(SextantPromo.title)
                        .font(SextantFont.title)
                        .foregroundStyle(Sextant.text)
                    Text(SextantPromo.lede)
                        .font(SextantFont.lede)
                        .foregroundStyle(Sextant.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // Routine nav affordance stays muted; gold is reserved for earned moments.
                Image(systemName: "arrow.up.right")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Sextant.textMuted)
            }
            .padding(.horizontal, 16) // SextantSpacing.s4
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: Sextant.radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Sextant.cardTop, Sextant.cardBottom],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .shadow(color: Sextant.shadow.opacity(0.18), radius: 10, x: 0, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Sextant.radius, style: .continuous)
                    .stroke(Sextant.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Sextant.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("sextantCard")
        .accessibilityLabel("\(SextantPromo.title). \(SextantPromo.lede)")
        .accessibilityHint("Opens sextant.run")
        .accessibilityAddTraits(.isLink)
    }
}

#Preview {
    ZStack {
        Color(white: 0.96).ignoresSafeArea()
        SextantCard().padding()
    }
}
