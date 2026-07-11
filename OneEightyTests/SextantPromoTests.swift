//  SextantPromoTests.swift
import XCTest
@testable import OneEighty

final class SextantPromoTests: XCTestCase {
    func testURLCarriesPostHogUTMTags() {
        let comps = URLComponents(url: SextantPromo.url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(
            (comps.queryItems ?? []).map { ($0.name, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )

        XCTAssertEqual(comps.scheme, "https", "https keeps it universal-link compatible")
        XCTAssertEqual(comps.host, "sextant.run")
        XCTAssertEqual(items["utm_source"], "oneeighty")
        XCTAssertEqual(items["utm_medium"], "cross-promo")
        XCTAssertEqual(items["utm_campaign"], "home-card")
    }

    func testCopyIsPresentAndHasNoEmDash() {
        XCTAssertFalse(SextantPromo.title.isEmpty)
        XCTAssertFalse(SextantPromo.lede.isEmpty)
        XCTAssertFalse(SextantPromo.lede.contains("\u{2014}"), "No em dashes in user-facing copy")
        XCTAssertFalse(SextantPromo.title.contains("\u{2014}"), "No em dashes in user-facing copy")
    }
}
