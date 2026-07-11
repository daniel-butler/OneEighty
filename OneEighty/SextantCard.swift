//
//  SextantCard.swift
//  OneEighty
//
//  A quiet, persistent awareness card pointing to Sextant (sextant.run), the
//  run-analysis companion. Cross-promo: people using a running-cadence metronome
//  are structured runners, which is Sextant's beachhead audience.
//
//  Styled as a self-contained dark, raised "billboard" using Sextant's own brand
//  tokens and logomark. Content (copy + link) is remotely controllable via a
//  static JSON on the CDN so the card can change when Sextant goes live, without
//  an app update. It ships with the current card as the bundled default and
//  falls back to it (or the last cached copy) whenever the fetch is unavailable,
//  so it never blocks the UI or breaks offline.
//
//  Token values and mark geometry are vendored (scoped, minimal) from the brand
//  source of truth: running-app-backend `logos/`. Keep them in sync if the brand
//  moves.
//

import SwiftUI
import Combine
import CoreText
import os

private let logger = Logger(subsystem: "app.rekuro.OneEighty", category: "SextantCard")

// MARK: - Brand fonts (bundled, registered at runtime)
// IBM Plex Mono (engraved overline) + Hanken Grotesk (UI text), both SIL OFL.
// Registered process-wide on first use; Font.custom falls back to the system
// font if registration ever fails.

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
    static var overline: Font { .custom("IBMPlexMono-Medium", size: 11, relativeTo: .caption2) }
    static var title: Font { .custom("HankenGrotesk-SemiBold", size: 17, relativeTo: .headline) }
    static var lede: Font { .custom("HankenGrotesk-Regular", size: 14, relativeTo: .subheadline) }
}

// MARK: - Brand tokens (scoped, vendored). Fixed dark: Sextant leads dark, and a
// raised surface + bevel + shadow keep the card separated from the host in both
// light and dark.

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
    static let cardTop      = Color(sxHex: 0x172A35) // raised surface, lighter at top
    static let cardBottom   = Color(sxHex: 0x0F1B26)
    static let bevelTop     = Color(sxHex: 0x33505F) // catch-light on the raised edge
    static let border       = Color(sxHex: 0x213947) // darker bottom edge of the bevel
    static let text         = Color(sxHex: 0xF1ECE0) // bone
    static let textMuted    = Color(sxHex: 0x9AA7B4)
    static let gold         = Color(sxHex: 0xEBB85E) // accent, earned moments only

    /// The signature "ascent" ramp: coral effort warming into gold light.
    static let ascent = [Color(sxHex: 0xE0573F), Color(sxHex: 0xEC8A52),
                         Color(sxHex: 0xF3BC63), Color(sxHex: 0xF8E2A6)]

    static let radius: CGFloat = 12
}

// MARK: - Remote-controllable content

/// The card's copy and destination. Decoded from the CDN JSON, and also the
/// shape of the bundled default. `enabled` lets the card be pulled remotely.
struct SextantPromoContent: Codable, Equatable {
    var enabled: Bool
    var overline: String
    var title: String
    var lede: String
    var url: URL
}

/// Bundled defaults and endpoints. The static copy constants are the shipped
/// fallback and the source of the bundled default.
enum SextantPromo {
    static let overline = "SEE PAST THE AVERAGES"
    static let title = "Sextant: Run Analysis"
    static let lede = "ChatGPT for your runs, without the slop."

    /// https so it doubles as a universal link once Sextant's deep links ship,
    /// with UTM params for PostHog attribution.
    static let url = URL(string:
        "https://sextant.run/?utm_source=oneeighty&utm_medium=cross-promo&utm_campaign=home-card"
    )!

    /// Static JSON the app polls so the card can flip when Sextant goes live.
    static let configURL = URL(string: "https://sextant.run/promo/oneeighty.json")!

    static var bundledDefault: SextantPromoContent {
        SextantPromoContent(enabled: true, overline: overline, title: title, lede: lede, url: url)
    }
}

/// Holds the card content: starts from the last cached copy (or the bundled
/// default), then refreshes from the CDN. A failed or slow fetch is a no-op, the
/// current content stays, so the card is offline-first and never blocks.
@MainActor
final class SextantPromoStore: ObservableObject {
    @Published private(set) var content: SextantPromoContent

    private static let cacheKey = "sextant.promo.content.v1"

    init() {
        content = Self.cached() ?? SextantPromo.bundledDefault
    }

    func refresh() async {
        var request = URLRequest(url: SextantPromo.configURL)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let remote = try JSONDecoder().decode(SextantPromoContent.self, from: data)
            guard remote != content else { return }
            content = remote
            Self.store(remote)
        } catch {
            logger.info("Sextant promo refresh skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func cached() -> SextantPromoContent? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(SextantPromoContent.self, from: data)
    }

    private static func store(_ content: SextantPromoContent) {
        if let data = try? JSONEncoder().encode(content) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}

// MARK: - The logomark

/// The Sextant mark, small-glyph form: a two-rep interval HR trace settling onto
/// a gold goal waypoint. Trace stroked with the ascent gradient. Drawn natively
/// so it stays crisp at any size. Geometry mirrors `logos/logomark-small.svg`.
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
                    startPoint: p(28, 40), endPoint: p(28, 0)
                ),
                style: StrokeStyle(lineWidth: 5 * min(sx, sy), lineCap: .round, lineJoin: .round)
            )

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

/// A low-key, always-present dark, raised card at the top of the main screen.
/// Awareness, not conversion: a sister-app shelf, not a banner. Content is
/// remote-controllable; tapping opens Sextant.
struct SextantCard: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var store = SextantPromoStore()

    var body: some View {
        let _ = sextantFontsRegistered // register bundled brand fonts before first render
        Group {
            if store.content.enabled {
                card(store.content)
            }
        }
        .task { await store.refresh() }
    }

    private func card(_ content: SextantPromoContent) -> some View {
        Button {
            logger.info("Sextant card tapped, opening \(content.url.absoluteString, privacy: .public)")
            openURL(content.url)
        } label: {
            HStack(spacing: 12) {
                SextantMark()

                VStack(alignment: .leading, spacing: 3) {
                    Text(content.overline)
                        .font(SextantFont.overline)
                        .tracking(1.4)
                        .foregroundStyle(Sextant.textMuted)
                    Text(content.title)
                        .font(SextantFont.title)
                        .foregroundStyle(Sextant.text)
                    Text(content.lede)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: Sextant.radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Sextant.cardTop, Sextant.cardBottom],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    // Drop shadow lifts the dark card off a light host; on a dark
                    // host the raised read comes from the lighter surface + bevel.
                    .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Sextant.radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Sextant.bevelTop, Sextant.border],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Sextant.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("sextantCard")
        .accessibilityLabel("\(content.title). \(content.lede)")
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
