//  SextantPromoStoreTests.swift
import XCTest
@testable import OneEighty

@MainActor
final class SextantPromoStoreTests: XCTestCase {

    private let suiteName = "SextantPromoStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: SextantPromo.configURL, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func payload(enabled: Bool = true,
                         overline: String = "OVERLINE",
                         title: String = "Title",
                         lede: String = "Lede",
                         url: String = "https://sextant.run/live") -> Data {
        """
        {"enabled":\(enabled),"overline":"\(overline)","title":"\(title)","lede":"\(lede)","url":"\(url)"}
        """.data(using: .utf8)!
    }

    private func makeStore(
        fetch: @escaping (URL) async throws -> (Data, URLResponse)
    ) -> SextantPromoStore {
        SextantPromoStore(defaults: defaults, fetch: fetch)
    }

    // MARK: - parse (pure)

    func testParseAcceptsValid200Payload() {
        let content = SextantPromoStore.parse(data: payload(title: "Sextant"), response: httpResponse(200))
        XCTAssertEqual(content?.title, "Sextant")
        XCTAssertEqual(content?.enabled, true)
    }

    func testParseRejectsNon200() {
        XCTAssertNil(SextantPromoStore.parse(data: payload(), response: httpResponse(404)))
    }

    func testParseRejectsMalformedJSON() {
        let bad = Data("not json".utf8)
        XCTAssertNil(SextantPromoStore.parse(data: bad, response: httpResponse(200)))
    }

    // MARK: - refresh

    func testRefreshAppliesRemoteContent() async {
        let store = makeStore { _ in (self.payload(title: "Live Title"), self.httpResponse(200)) }
        await store.refresh()
        XCTAssertEqual(store.content.title, "Live Title")
    }

    func testRefreshKeepsDefaultOnNon200() async {
        let store = makeStore { _ in (self.payload(title: "Nope"), self.httpResponse(500)) }
        await store.refresh()
        XCTAssertEqual(store.content, SextantPromo.bundledDefault)
    }

    func testRefreshKeepsDefaultOnNetworkError() async {
        let store = makeStore { _ in throw URLError(.timedOut) }
        await store.refresh()
        XCTAssertEqual(store.content, SextantPromo.bundledDefault)
    }

    func testRefreshHonorsDisabledFlag() async {
        let store = makeStore { _ in (self.payload(enabled: false), self.httpResponse(200)) }
        await store.refresh()
        XCTAssertFalse(store.content.enabled)
    }

    // MARK: - init / caching

    func testStartsFromBundledDefaultWithNoCache() {
        let store = makeStore { _ in (Data(), self.httpResponse(200)) }
        XCTAssertEqual(store.content, SextantPromo.bundledDefault)
    }

    func testRefreshPersistsSoAFreshStoreStartsFromCache() async {
        let first = makeStore { _ in (self.payload(title: "Cached"), self.httpResponse(200)) }
        await first.refresh()

        // A brand-new store over the same defaults reads the cache immediately,
        // before any network refresh.
        let reopened = SextantPromoStore(defaults: defaults, fetch: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(reopened.content.title, "Cached")
    }
}
