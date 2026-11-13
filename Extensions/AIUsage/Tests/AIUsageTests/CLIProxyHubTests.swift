import XCTest
@testable import AIUsage

final class CLIProxyHubTests: XCTestCase {
    private var root: URL!
    private static let hubURL = "https://hub.synthetic.ts.net:8317"

    override func setUp() {
        root = temporaryDirectory()
    }

    private func write(_ text: String, to relative: String) {
        let url = root.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    private func writeKeys(url: String = hubURL) {
        write(#"{"url": "\#(url)", "management_key": "mgmt-synthetic", "access_key": "sk-synthetic"}"#,
              to: ".config/cliproxyapi/hub-keys.json")
    }

    private var locator: CLIProxyHubLocator {
        CLIProxyHubLocator(environment: [:], home: root, codexHome: CodexHome(environment: [:], home: root))
    }

    // MARK: Discovery

    func testFindsTheHubEachToolIsPointedAt() throws {
        writeKeys()
        write(#"{"env": {"ANTHROPIC_BASE_URL": "\#(Self.hubURL)", "ANTHROPIC_AUTH_TOKEN": "sk-synthetic"}}"#, to: ".claude/settings.json")
        write("""
        model = "gpt-synthetic"
        openai_base_url = "\(Self.hubURL)/v1"

        [projects."/tmp"]
        trust_level = "trusted"
        """, to: ".codex/config.toml")

        let claude = try XCTUnwrap(locator.hub(for: .claude))
        XCTAssertEqual(claude.baseURL.absoluteString, Self.hubURL)
        XCTAssertEqual(claude.managementKey, "mgmt-synthetic")
        XCTAssertEqual(locator.hub(for: .codex), claude)
        XCTAssertNil(locator.hub(for: .cursor))
        XCTAssertEqual(locator.hosts, ["hub.synthetic.ts.net"])
    }

    func testCodexModelProviderSectionCounts() {
        writeKeys()
        write("""
        model_provider = "hub"

        [model_providers.hub]
        name = "Hub"
        base_url = "\(Self.hubURL)/v1"
        """, to: ".codex/config.toml")
        XCTAssertNotNil(locator.hub(for: .codex))
    }

    func testNoHubWithoutAMatchingKeyOrRoute() {
        // Pointed at the hub, but no key saved.
        write(#"{"env": {"ANTHROPIC_BASE_URL": "\#(Self.hubURL)"}}"#, to: ".claude/settings.json")
        XCTAssertNil(locator.hub(for: .claude))
        // A key for another host or port.
        writeKeys(url: "https://hub.synthetic.ts.net:9999")
        XCTAssertNil(locator.hub(for: .claude))
        // Never over plain HTTP.
        writeKeys(url: "http://hub.synthetic.ts.net:8317")
        XCTAssertNil(locator.hub(for: .claude))
        // Codex talking to OpenAI directly.
        writeKeys()
        write(#"model = "gpt-synthetic""#, to: ".codex/config.toml")
        XCTAssertNil(locator.hub(for: .codex))
    }

    func testKeychainKeyWinsAndOnlyItCanBeRemoved() throws {
        writeKeys()
        write(#"{"env": {"ANTHROPIC_BASE_URL": "\#(Self.hubURL)"}}"#, to: ".claude/settings.json")
        let keychain = FakeKeychain()
        var hubs = locator
        hubs.secrets = keychain
        XCTAssertEqual(hubs.knownRoute(for: .claude), .connected(host: "hub.synthetic.ts.net", removable: false))

        let entered = CLIProxyHub(baseURL: URL(string: Self.hubURL)!, managementKey: "mgmt-entered")
        XCTAssertTrue(hubs.save(entered))
        XCTAssertEqual(hubs.hub(for: .claude)?.managementKey, "mgmt-entered")
        XCTAssertEqual(hubs.knownRoute(for: .claude), .connected(host: "hub.synthetic.ts.net", removable: true))
        XCTAssertEqual(hubs.knownRoute(for: .codex), .direct)

        hubs.forget()
        XCTAssertEqual(hubs.hub(for: .claude)?.managementKey, "mgmt-synthetic")
    }

    func testRoutesNeedingAProbe() {
        var hubs = locator
        hubs.secrets = FakeKeychain()
        // Pointed at an unknown proxy: XNotch can't tell without asking it.
        write(#"{"env": {"ANTHROPIC_BASE_URL": "https://proxy.example.com/anthropic"}}"#, to: ".claude/settings.json")
        XCTAssertNil(hubs.knownRoute(for: .claude))
        XCTAssertEqual(hubs.routedOrigin(for: .claude)?.absoluteString, "https://proxy.example.com")
        XCTAssertEqual(hubs.routedHosts, ["proxy.example.com"])
        // The provider's own API is no proxy.
        write(#"{"env": {"ANTHROPIC_BASE_URL": "https://api.anthropic.com"}}"#, to: ".claude/settings.json")
        XCTAssertEqual(hubs.knownRoute(for: .claude), .direct)
    }

    func testAddressesKeepTheKeyOffPlainHTTPNetworks() {
        XCTAssertEqual(CLIProxyHubLocator.origin("hub.example.ts.net:8317")?.absoluteString, "https://hub.example.ts.net:8317")
        XCTAssertEqual(CLIProxyHubLocator.origin(" https://hub.example.ts.net:8317/v1 ")?.absoluteString, "https://hub.example.ts.net:8317")
        XCTAssertEqual(CLIProxyHubLocator.origin("http://127.0.0.1:8317")?.absoluteString, "http://127.0.0.1:8317")
        XCTAssertEqual(CLIProxyHubLocator.origin("http://localhost:8317/v1")?.absoluteString, "http://localhost:8317")
        XCTAssertNil(CLIProxyHubLocator.origin("http://192.168.1.20:8317"))
        XCTAssertNil(CLIProxyHubLocator.origin("ftp://hub.example.ts.net"))
    }

    func testLocalHubOverPlainHTTP() {
        writeKeys(url: "http://127.0.0.1:8317")
        write(#"openai_base_url = "http://127.0.0.1:8317/v1""#, to: ".codex/config.toml")
        XCTAssertEqual(locator.hub(for: .codex)?.baseURL.absoluteString, "http://127.0.0.1:8317")
    }

    // MARK: Probe

    private func probe(root: HTTPResponse?, management: HTTPResponse?) async -> ProxyRoute {
        let transport = MockTransport { request in
            let response = request.url?.path == "/v0/management/config" ? management : root
            guard let response else { throw URLError(.cannotConnectToHost) }
            return response
        }
        let route = await CLIProxyProbe.probe(URL(string: Self.hubURL)!, transport: transport)
        for request in transport.requests { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) }
        return route
    }

    private static let banner = MockTransport.json(200, #"{"endpoints": ["POST /v1/chat/completions"], "message": "CLI Proxy API Server"}"#)

    func testProbeTellsHubsFromOtherProxies() async {
        let origin = URL(string: Self.hubURL)!
        let askForKey = MockTransport.json(401, #"{"error": "missing management key"}"#)
        var route = await probe(root: Self.banner, management: askForKey)
        XCTAssertEqual(route, .cliProxy(origin: origin, managementEnabled: true))
        route = await probe(root: Self.banner, management: MockTransport.json(404, "404 page not found"))
        XCTAssertEqual(route, .cliProxy(origin: origin, managementEnabled: false))
        // A hub with a different banner still gives itself away by asking for a management key.
        route = await probe(root: MockTransport.json(404, ""), management: askForKey)
        XCTAssertEqual(route, .cliProxy(origin: origin, managementEnabled: true))
        route = await probe(root: MockTransport.json(200, "<html>LiteLLM</html>"), management: MockTransport.json(404, ""))
        XCTAssertEqual(route, .otherProxy(host: "hub.synthetic.ts.net"))
        route = await probe(root: nil, management: nil)
        XCTAssertEqual(route, .unreachable(origin: origin))
    }

    func testInventoryCountsLoginsPerProvider() async throws {
        let hub = CLIProxyHub(baseURL: URL(string: Self.hubURL)!, managementKey: "mgmt-synthetic")
        let transport = MockTransport { _ in MockTransport.json(200, Self.authFiles) }
        let inventory = try await hub.inventory(transport: transport)
        XCTAssertEqual(inventory, [.codex: 2, .claude: 1])
    }

    func testCodexThroughAnUnconnectedProxySaysWhatToDo() async {
        write(#"openai_base_url = "\#(Self.hubURL)/v1""#, to: ".codex/config.toml")
        write(#"{"auth_mode": "apikey", "OPENAI_API_KEY": "sk-synthetic"}"#, to: ".codex/auth.json")
        var hubs = locator
        hubs.secrets = FakeKeychain()
        let provider = CodexUsageProvider(transport: MockTransport { _ in MockTransport.json(500, "") },
                                          codexHome: hubs.codexHome, hubs: hubs)
        do {
            _ = try await provider.fetch(FetchContext(now: referenceDate))
            XCTFail("Read limits without a hub or a ChatGPT login")
        } catch {
            assertFailure(error, .notConnected)
            XCTAssertTrue((error as! ProviderFailure).message.contains("Settings → AI Usage"))
        }
    }

    // MARK: Relay

    private static func relayed(_ status: Int, body: Data) -> HTTPResponse {
        let wrapped: [String: Any] = ["status_code": status, "header": ["Retry-After": ["30"]],
                                      "body": String(decoding: body, as: UTF8.self)]
        return HTTPResponse(statusCode: 200, headers: [:], data: try! JSONSerialization.data(withJSONObject: wrapped))
    }

    private static let authFiles = """
    {"files": [
      {"id": "codex-b-second@example.com.json", "provider": "codex", "auth_index": "idx-b", "email": "second@example.com", "status": "active"},
      {"id": "claude-x@example.com.json", "provider": "claude", "auth_index": "idx-claude", "email": "x@example.com", "status": "active"},
      {"id": "codex-a-first@example.com.json", "provider": "codex", "auth_index": "idx-a", "email": "first@example.com", "status": "active"},
      {"id": "codex-off.json", "provider": "codex", "auth_index": "idx-off", "disabled": true}
    ]}
    """

    private static func call(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testCodexReadsEveryHubLoginThroughTheRelay() async throws {
        writeKeys()
        write(#"openai_base_url = "\#(Self.hubURL)/v1""#, to: ".codex/config.toml")
        let transport = MockTransport { request in
            if request.url?.path == "/v0/management/auth-files" { return MockTransport.json(200, Self.authFiles) }
            let call = Self.call(request)
            guard (call["url"] as? String)?.hasSuffix("/wham/usage") == true else { return Self.relayed(404, body: Data()) }
            var usage = try! JSONSerialization.jsonObject(with: Fixture.data("codex_usage")) as! [String: Any]
            usage["user_id"] = "user-\(call["auth_index"]!)"
            usage["email"] = nil
            return Self.relayed(200, body: try! JSONSerialization.data(withJSONObject: usage))
        }
        // No auth.json at all: the hub holds the logins.
        let provider = CodexUsageProvider(transport: transport, codexHome: locator.codexHome, hubs: locator)
        let snapshot = try await provider.fetch(FetchContext(now: referenceDate))

        XCTAssertEqual(snapshot.source, .cliProxyHub)
        XCTAssertEqual(snapshot.coreWindows.map(\.shortLabel), ["Account 1", "Account 2"])
        XCTAssertTrue(snapshot.coreWindows.allSatisfy { $0.label.hasPrefix("Weekly") })
        XCTAssertEqual(snapshot.accountLabel, "first@example.com · second@example.com")
        XCTAssertEqual(Set(snapshot.windows.map(\.id)).count, snapshot.windows.count)

        for request in transport.requests {
            XCTAssertEqual(request.url?.host, "hub.synthetic.ts.net")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mgmt-synthetic")
        }
        let calls = transport.requests.filter { $0.url?.path == "/v0/management/api-call" }.map(Self.call)
        XCTAssertEqual(Set(calls.compactMap { $0["auth_index"] as? String }), ["idx-a", "idx-b"])
        for call in calls {
            XCTAssertEqual((call["header"] as? [String: String])?["Authorization"], "Bearer $TOKEN$")
            XCTAssertEqual(URL(string: call["url"] as? String ?? "")?.host, "chatgpt.com")
        }
    }

    func testOneUnreadableLoginKeepsItsPlace() async throws {
        writeKeys()
        write(#"openai_base_url = "\#(Self.hubURL)/v1""#, to: ".codex/config.toml")
        let transport = MockTransport { request in
            if request.url?.path == "/v0/management/auth-files" { return MockTransport.json(200, Self.authFiles) }
            let call = Self.call(request)
            if call["auth_index"] as? String == "idx-b" { return Self.relayed(401, body: Data()) }
            return Self.relayed(200, body: Fixture.data("codex_usage"))
        }
        let provider = CodexUsageProvider(transport: transport, codexHome: locator.codexHome, hubs: locator)
        let snapshot = try await provider.fetch(FetchContext(includeExtras: false, now: referenceDate))
        XCTAssertEqual(snapshot.coreWindows.count, 2)
        XCTAssertNotNil(snapshot.coreWindows[0].percentUsed)
        XCTAssertNil(snapshot.coreWindows[1].percentUsed)
        XCTAssertTrue(snapshot.coreWindows[1].detail?.contains("on the hub") == true)
    }

    func testClaudeReadsTheHubLoginWithItsPlan() async throws {
        writeKeys()
        write(#"{"env": {"ANTHROPIC_BASE_URL": "\#(Self.hubURL)"}}"#, to: ".claude/settings.json")
        let transport = MockTransport { request in
            if request.url?.path == "/v0/management/auth-files" { return MockTransport.json(200, Self.authFiles) }
            let url = URL(string: Self.call(request)["url"] as? String ?? "")
            if url?.path == "/api/oauth/profile" {
                return Self.relayed(200, body: Data(#"""
                {"account": {"uuid": "acct-1", "email": "x@example.com"},
                 "organization": {"uuid": "org-1", "organization_type": "claude_max", "rate_limit_tier": "default_claude_max_20x"}}
                """#.utf8))
            }
            return Self.relayed(200, body: Data(#"""
            {"five_hour": {"utilization": 12, "resets_at": "2026-09-20T05:00:00Z"},
             "seven_day": {"utilization": 40, "resets_at": "2026-09-25T00:00:00Z"}}
            """#.utf8))
        }
        // The Keychain is never consulted on the hub path.
        let provider = ClaudeUsageProvider(transport: transport, locator: ClaudeCredentialLocator(keychain: FakeKeychain()),
                                           keychainAllowed: { false }, hubs: locator)
        let snapshot = try await provider.fetch(FetchContext(now: referenceDate))
        XCTAssertEqual(snapshot.source, .cliProxyHub)
        XCTAssertEqual(snapshot.planLabel, "Max 20x")
        XCTAssertEqual(snapshot.coreWindows.map(\.percentUsed), [12, 40])
        XCTAssertEqual(snapshot.accountLabel, "x@example.com")
    }

    func testRelayOnlyCarriesOfficialHosts() async {
        let hub = CLIProxyHub(baseURL: URL(string: Self.hubURL)!, managementKey: "mgmt-synthetic")
        let transport = MockTransport { _ in MockTransport.json(200, "{}") }
        let relay = CLIProxyRelayTransport(hub: hub, authIndex: "idx-a", transport: transport)
        do {
            _ = try await relay.send(URLRequest(url: URL(string: "https://evil.example.com/steal")!))
            XCTFail("Relayed a request to an unknown host")
        } catch {
            XCTAssertEqual(error as? TransportError, .hostNotAllowed("evil.example.com"))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testLockoutWaitsInsteadOfBlamingTheKey() async {
        let hub = CLIProxyHub(baseURL: URL(string: Self.hubURL)!, managementKey: "mgmt-synthetic")
        let transport = MockTransport { _ in
            MockTransport.json(403, #"{"error": "IP banned due to too many failed attempts. Try again in 25m37s"}"#)
        }
        do {
            _ = try await hub.accounts(provider: .codex, transport: transport)
            XCTFail("Ignored the lockout")
        } catch {
            guard let failure = error as? ProviderFailure, case let .rateLimited(retryAfter?) = failure.kind else {
                return XCTFail("Expected a rate limit, got \(error)")
            }
            XCTAssertEqual(retryAfter.timeIntervalSinceNow, 25 * 60 + 37, accuracy: 5)
            XCTAssertTrue(failure.message.contains("26 min"))
            XCTAssertFalse(failure.message.contains("rejected"))
        }
        XCTAssertEqual(CLIProxyHub.lockout(in: MockTransport.json(403, "try again in 1h2m")), 3720)
        XCTAssertNil(CLIProxyHub.lockout(in: MockTransport.json(403, "banned")))
    }

    func testRejectedManagementKeyExplainsItself() async {
        let hub = CLIProxyHub(baseURL: URL(string: Self.hubURL)!, managementKey: "wrong")
        let transport = MockTransport { _ in MockTransport.json(401, #"{"error": "invalid management key"}"#) }
        do {
            _ = try await hub.accounts(provider: .codex, transport: transport)
            XCTFail("Accepted a rejected key")
        } catch {
            assertFailure(error, .unauthorized)
            XCTAssertTrue((error as! ProviderFailure).message.contains("management key"))
        }
    }
}
