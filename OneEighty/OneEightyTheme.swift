//
//  OneEightyTheme.swift
//  OneEighty
//
//  OneEighty's brand color layer: the warm coral-to-gold identity from the
//  marketing site, replacing stock iOS blue. Theme-adaptive (light/dark) and
//  kept in the warm "Rekuro house" family, while the running state (STOP) stays
//  a clear red so the control is never ambiguous.
//

import SwiftUI

private extension Color {
    init(oeHex hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Theme-adaptive color, resolved per trait at render time.
    static func oeDynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .light
                ? UIColor(Color(oeHex: light))
                : UIColor(Color(oeHex: dark))
        })
    }
}

enum OE {
    /// Warm brand accent that replaces iOS system blue on tinted controls
    /// (the +/- steppers, the volume track).
    static let accent = Color.oeDynamic(dark: 0xF2683C, light: 0xD24E23)

    /// STOP: a clear, conventional red, tuned warm to stay in-family but kept
    /// distinct from the coral accent so the running state reads instantly.
    static let stop = Color.oeDynamic(dark: 0xE23D3D, light: 0xC62F2F)

    /// The signature "ascent" ramp: coral effort warming into gold. Used for the
    /// cadence readout and the START fill. Deepened on light so it holds on white.
    static let ascent = LinearGradient(
        colors: [
            .oeDynamic(dark: 0xE0573F, light: 0xD24E23),
            .oeDynamic(dark: 0xEC8A52, light: 0xDC7A34),
            .oeDynamic(dark: 0xF3BC63, light: 0xCF9A32),
            .oeDynamic(dark: 0xF8E2A6, light: 0xB98523)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}
