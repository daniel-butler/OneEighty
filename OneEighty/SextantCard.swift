//
//  SextantCard.swift
//  OneEighty
//
//  A quiet, persistent awareness card pointing to Sextant Run (sextant.run),
//  the run-analysis companion. Cross-promo: people using a running-cadence
//  metronome are structured runners, which is Sextant's beachhead audience.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "app.rekuro.OneEighty", category: "SextantCard")

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

/// A low-key, always-present card at the top of the main screen. Its job is
/// awareness, not conversion: it should read like a sister-app shelf, not a
/// banner. Tapping opens Sextant.
struct SextantCard: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            logger.info("Sextant card tapped, opening \(SextantPromo.url.absoluteString, privacy: .public)")
            openURL(SextantPromo.url)
        } label: {
            HStack(spacing: 12) {
                // Typographic mark, deliberately not a nautical/sextant icon.
                Text("\u{25C7}")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(SextantPromo.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(SextantPromo.lede)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    SextantCard()
        .padding()
}
