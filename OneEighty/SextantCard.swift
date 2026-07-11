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
import os

private let logger = Logger(subsystem: "app.rekuro.OneEighty", category: "SextantCard")

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
}

private enum Sextant {
    // Ink surfaces / text
    static let ink        = Color(sxHex: 0x0A131C) // bg
    static let surface    = Color(sxHex: 0x101E2A) // raised surface
    static let border     = Color(sxHex: 0x1E3340)
    static let text       = Color(sxHex: 0xF1ECE0) // bone
    static let textMuted  = Color(sxHex: 0x9AA7B4)
    static let textFaint  = Color(sxHex: 0x62727F)
    static let gold       = Color(sxHex: 0xEBB85E) // accent — earned moments only

    // The signature "ascent" ramp: coral effort warming into gold light.
    static let ascent = [Color(sxHex: 0xE0573F), Color(sxHex: 0xEC8A52),
                         Color(sxHex: 0xF3BC63), Color(sxHex: 0xF8E2A6)]

    static let radius: CGFloat = 16 // SextantRadius.lg
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

/// A low-key, always-present dark card at the top of the main screen. Its job is
/// awareness, not conversion: it reads like a sister-app shelf, not a banner.
/// Tapping opens Sextant.
struct SextantCard: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            logger.info("Sextant card tapped, opening \(SextantPromo.url.absoluteString, privacy: .public)")
            openURL(SextantPromo.url)
        } label: {
            HStack(spacing: 12) {
                SextantMark()

                VStack(alignment: .leading, spacing: 2) {
                    Text(SextantPromo.title)
                        .font(.system(size: 16, weight: .semibold)) // Hanken Grotesk SemiBold token
                        .foregroundStyle(Sextant.text)
                    Text(SextantPromo.lede)
                        .font(.system(size: 13)) // Hanken Grotesk body token
                        .foregroundStyle(Sextant.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // Routine nav affordance stays muted — gold is reserved for earned moments.
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Sextant.textFaint)
            }
            .padding(.horizontal, 16) // SextantSpacing.s4
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: Sextant.radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Sextant.surface, Sextant.ink],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
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
