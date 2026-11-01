import XCTest
import WebKit
@testable import Uchiyomi

@MainActor
final class ReaderLifecycleTests: XCTestCase {
    private func waitForPath(_ model: ReaderModel, _ path: String) async throws {
        let view = try XCTUnwrap(model.webView)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.readyState === 'complete' && location.pathname === '\(path)'")) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ClientError.invalid("The reader did not reach \(path).")
    }

    func testColdLaunchStartsAtHomeWhileResumeKeepsCurrentPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root)
        let profile = try store.profile(for: URL(string: "https://127.0.0.1:9")!, in: .init())
        try store.save(.init(profiles: [profile], selectedID: profile.id))
        let cache = AssetCache(root: store.directory(for: profile).appendingPathComponent("ui"))
        let ui = try await cache.prepare(client: ReaderFixture()) { _, _ in }
        try await cache.confirm(ui)
        var model = ReaderModel(root: root)
        do {
            await model.restore()
            try await waitForPath(model, "/")
            model.webView?.load(URLRequest(url: URL(string: "/reader/?book=fixture-1", relativeTo: profile.localOrigin)!.absoluteURL))
            try await waitForPath(model, "/reader/")
            await model.resume()
            try await waitForPath(model, "/reader/")

            // Release the view/listener and create a new model from persisted state,
            // as a process restart does. A previous reader URL must not be restored.
            await model.addServer()
            model = ReaderModel(root: root)
            await model.restore()
            try await waitForPath(model, "/")
            XCTAssertEqual(model.selectedID, profile.id)
            let query = try await model.webView?.evaluateJavaScript("location.search") as? String
            XCTAssertEqual(query, "")
        } catch {
            await model.addServer()
            try? KeychainCookieVault(profileID: profile.id).remove()
            try? await removeFixtureStore(profile.id)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await model.addServer()
        try KeychainCookieVault(profileID: profile.id).remove()
        try await removeFixtureStore(profile.id)
        try FileManager.default.removeItem(at: root)
    }

    private func removeFixtureStore(_ id: UUID) async throws {
        // A fresh simulator can retain WebKit's network process after the view is gone.
        // The app exposes retry on removal failure; fixture teardown waits for that same
        // asynchronous shutdown without making lifecycle assertions depend on its timing.
        for attempt in 0..<10 {
            do { try await NativeWebView.removeStore(for: id); return }
            catch {
                if attempt == 9 { throw error }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
    func testRetiredReaderCannotAcknowledgeReopenedGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root)
        let profile = try store.profile(for: URL(string: "https://127.0.0.1:9")!, in: .init())
        try store.save(.init(profiles: [profile], selectedID: profile.id))
        let cache = AssetCache(root: store.directory(for: profile).appendingPathComponent("ui"))
        _ = try await cache.prepare(client: ReaderFixture()) { _, _ in }
        let model = ReaderModel(root: root)
        await model.restore()
        var retired: WKWebView? = try XCTUnwrap(model.webView)
        for _ in 0..<100 {
            if (try? await retired?.evaluateJavaScript("document.readyState === 'complete' && !!window.uchiyomiNative")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Reopening the same cache generation still creates a different reader instance.
        await model.choose(profile)
        XCTAssertNotNil(model.webView)
        XCTAssertFalse(model.webView === retired)
        XCTAssertTrue(model.awaitingConfirmation)
        model.error = "Current reader has not started"
        _ = try await retired?.evaluateJavaScript("window.uchiyomiNative.ready(); true")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.awaitingConfirmation, "Retired web view acknowledged the new reader")
        XCTAssertEqual(model.error, "Current reader has not started")
        let pending = try await cache.needsConfirmation()
        XCTAssertTrue(pending, "Retired callback confirmed the cached generation")
        retired = nil
        for _ in 0..<100 {
            if (try? await model.webView?.evaluateJavaScript("document.readyState === 'complete' && !!window.uchiyomiNative")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try await model.webView?.evaluateJavaScript("window.uchiyomiNative.ready(); true")
        for _ in 0..<100 {
            if !model.awaitingConfirmation { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.awaitingConfirmation)
        XCTAssertNil(model.error)
        let confirmed = try await cache.needsConfirmation()
        XCTAssertFalse(confirmed, "The current reader must still be able to acknowledge startup")
        await model.addServer()
        try KeychainCookieVault(profileID: profile.id).remove()
        try await removeFixtureStore(profile.id)
        try FileManager.default.removeItem(at: root)
    }

    func testAddingServerCannotOverlapProfileSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root)
        let first = try store.profile(for: URL(string: "https://127.0.0.1:9")!, in: .init())
        let second = try store.profile(for: URL(string: "https://127.0.0.1:10")!, in: .init(profiles: [first]))
        try store.save(.init(profiles: [first, second], selectedID: first.id))
        for profile in [first, second] {
            let cache = AssetCache(root: store.directory(for: profile).appendingPathComponent("ui"))
            let ui = try await cache.prepare(client: ReaderFixture()) { _, _ in }
            try await cache.confirm(ui)
        }
        let model = ReaderModel(root: root)
        await model.restore()
        XCTAssertNil(model.error)
        // Keep the old view alive to reproduce SwiftUI retaining it across a transition.
        var retired: WKWebView? = try XCTUnwrap(model.webView)
        let adding = Task { await model.addServer() }
        for _ in 0..<100 {
            if model.webView == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(model.webView)
        XCTAssertTrue(model.busy, "Server teardown must exclude a second transition")
        await model.choose(second)
        XCTAssertEqual(model.selectedID, first.id, "Selection changed during teardown")
        XCTAssertNil(model.webView, "A second reader opened during teardown")
        withExtendedLifetime(retired) {}
        retired = nil
        await adding.value
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.addingServer)
        XCTAssertEqual(model.address, "")
        // Selecting a saved server works again once teardown completes.
        await model.choose(second)
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertNotNil(model.webView)
        await model.addServer()
        for profile in [first, second] {
            try KeychainCookieVault(profileID: profile.id).remove()
            try await removeFixtureStore(profile.id)
        }
        try FileManager.default.removeItem(at: root)
    }
}

private struct ReaderFixture: AssetFetching {
    private let paths = ["/index.html", "/downloads/index.html", "/reader/index.html", "/index.txt", "/downloads/index.txt", "/reader/index.txt", "/_next/static/reader.js"]
    private let bytes = Data("<!doctype html><title>Reader fixture</title>".utf8)
    func assetResponse(_ path: String, maxBytes: Int) async throws -> HTTPResponse {
        if path == "/mobile-assets.json" {
            let manifest = AssetManifest(schemaVersion: 1, protocolVersion: 1, offlineSchemaVersion: 2,
                buildId: AssetManifest.digest(bytes), files: paths.map {
                    .init(path: $0, size: bytes.count, sha256: AssetManifest.digest(bytes), contentType: "text/html")
                })
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: try JSONEncoder().encode(manifest))
        }
        return HTTPResponse(status: 200, body: bytes)
    }
}
