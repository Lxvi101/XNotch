import XCTest
@testable import Shelves

final class LinkRuleTests: XCTestCase {
    private let pinterest = LinkRule.builtIn[0]
    private let images = LinkRule.builtIn[1]

    func testGlob() {
        XCTAssertTrue(LinkRule.glob("/pin/*", matches: "/pin/457608012162480894/"))
        XCTAssertTrue(LinkRule.glob("*.JPG", matches: "/a/b/photo.jpg"))
        XCTAssertTrue(LinkRule.glob("a*b*c", matches: "aXXbYYc"))
        XCTAssertFalse(LinkRule.glob("/pin/*", matches: "/ideas/pin/1"))
        XCTAssertFalse(LinkRule.glob("a*b", matches: "aXXbY"))
    }

    func testHostCoversSubdomains() {
        XCTAssertTrue(LinkRule.host("pinterest.com", matches: "pinterest.*"))
        XCTAssertTrue(LinkRule.host("de.pinterest.com", matches: "pinterest.*"))
        XCTAssertTrue(LinkRule.host("www.pinterest.co.uk", matches: "pinterest.*"))
        XCTAssertFalse(LinkRule.host("notpinterest.com", matches: "pinterest.*"))
    }

    func testPinterestRuleCoversPinsOnly() {
        XCTAssertTrue(pinterest.matches(URL(string: "https://de.pinterest.com/pin/457608012162480894/")!))
        XCTAssertFalse(pinterest.matches(URL(string: "https://de.pinterest.com/search/pins/?q=red")!))
        XCTAssertFalse(pinterest.matches(URL(string: "ftp://pinterest.com/pin/1/")!))
    }

    func testFirstEnabledRuleWins() {
        let pin = URL(string: "https://pinterest.com/pin/1/")!
        XCTAssertEqual(LinkResolver.rule(for: pin, in: LinkRule.builtIn)?.id, pinterest.id)
        var off = pinterest
        off.isEnabled = false
        XCTAssertNil(LinkResolver.rule(for: pin, in: [off, images]))
        XCTAssertEqual(LinkResolver.rule(for: URL(string: "https://example.com/a/cat.webp")!, in: LinkRule.builtIn)?.id, images.id)
        XCTAssertNil(LinkResolver.rule(for: URL(string: "https://example.com/article")!, in: LinkRule.builtIn))
    }

    func testRewriteTriesOriginalFirst() async throws {
        var rule = LinkRule(name: "Test", hosts: ["i.pinimg.com"], source: .link, find: "/\\d+x/", replace: "/originals/")
        let url = URL(string: "https://i.pinimg.com/736x/86/ca/b4/86cab4.jpg")!
        let addresses = try await LinkResolver.addresses(for: url, with: rule)
        XCTAssertEqual(addresses.map(\.absoluteString), ["https://i.pinimg.com/originals/86/ca/b4/86cab4.jpg", url.absoluteString])
        rule.find = "(unclosed"
        do {
            _ = try await LinkResolver.addresses(for: url, with: rule)
            XCTFail("A bad expression should fail")
        } catch {}
    }

    func testPreviewImageTag() {
        let html = """
        <head><meta name="description" content="x"><meta content="https://i.pinimg.com/736x/a.jpg?x=1&amp;y=2" data-app="true" name="og:image" property="og:image"/>
        <meta property='twitter:image' content='https://example.com/t.jpg'></head>
        """
        XCTAssertEqual(LinkResolver.previewImage(in: html), "https://i.pinimg.com/736x/a.jpg?x=1&y=2")
        XCTAssertEqual(LinkResolver.previewImage(in: "<meta name=\"twitter:image\" content=\"/t.png\">"), "/t.png")
        XCTAssertNil(LinkResolver.previewImage(in: "<meta property=\"og:title\" content=\"x\">"))
    }

    func testSavedRulesDecode() throws {
        let data = try JSONEncoder().encode(LinkRule.builtIn)
        XCTAssertEqual(try JSONDecoder().decode([LinkRule].self, from: data), LinkRule.builtIn)
    }
}

/// Downloads a real pin. Skipped unless SHELVES_LIVE=1.
final class LiveLinkTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHELVES_LIVE"] == "1", "Set SHELVES_LIVE=1 to download a pin")
    }

    func testPinterestPinBecomesItsOriginal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date()
        let file = try await LinkResolver.download(URL(string: "https://de.pinterest.com/pin/457608012162480894/")!,
                                                   with: LinkRule.builtIn[0], into: folder)
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        print("LIVE pin -> \(file.lastPathComponent) \(size) bytes in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        XCTAssertEqual(file.pathExtension, "jpg")
        XCTAssertGreaterThan(size, 10_000)
    }
}

@MainActor
final class LinkRuleFileTests: XCTestCase {
    func testHandWrittenRuleGetsDefaults() throws {
        let json = #"{"rules": [{"name": "Dribbble shots", "hosts": ["dribbble.com"], "paths": ["/shots/*"], "source": "previewImage"}]}"#
        let rules = try LinkRule.rules(from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertTrue(rules[0].isEnabled)
        XCTAssertFalse(rules[0].isBuiltIn)
        XCTAssertTrue(rules[0].matches(URL(string: "https://dribbble.com/shots/123-thing")!))
    }

    func testSingleRuleAndBareListImport() throws {
        let one = #"{"name": "A", "hosts": ["a.com"], "source": "link"}"#
        XCTAssertEqual(try LinkRule.rules(from: Data(one.utf8)).map(\.name), ["A"])
        XCTAssertEqual(try LinkRule.rules(from: Data("[\(one)]".utf8)).map(\.name), ["A"])
        XCTAssertThrowsError(try LinkRule.rules(from: Data(#"{"name": "No hosts"}"#.utf8)))
    }

    func testExportRoundTrips() throws {
        XCTAssertEqual(try LinkRule.rules(from: LinkRule.export(LinkRule.builtIn)), LinkRule.builtIn)
    }

    func testImportReplacesByIdAndAppendsNew() throws {
        let preferences = ShelvesPreferences(defaults: UserDefaults(suiteName: "import-\(UUID())")!)
        var pinterest = LinkRule.builtIn[0]
        pinterest.isEnabled = false
        let added = LinkRule(name: "B", hosts: ["b.com"], source: .link)
        XCTAssertEqual(try preferences.importLinkRules(from: LinkRule.export([pinterest, added])), 2)
        XCTAssertEqual(preferences.linkRules.map(\.id), LinkRule.builtIn.map(\.id) + [added.id])
        XCTAssertFalse(preferences.linkRules[0].isEnabled)
        XCTAssertTrue(preferences.linkRules[0].isBuiltIn)
    }
}
