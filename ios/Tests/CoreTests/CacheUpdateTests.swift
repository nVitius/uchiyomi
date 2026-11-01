import Foundation
import Testing
@testable import UchiyomiCore

private final class AssetFixture: AssetFetching {
    enum Failure { case none, interrupted, corrupt, changed, schema, cancelled }
    var failure: Failure = .none
    var manifestReads = 0
    var assetReads = 0
    let revision: String
    init(_ revision: String) { self.revision = revision }
    private let paths = ["/index.html", "/downloads/index.html", "/reader/index.html", "/index.txt", "/downloads/index.txt", "/reader/index.txt", "/_next/static/reader.js"]
    func bytes(_ path: String) -> Data { Data("\(revision) \(path)".utf8) }
    func assetResponse(_ path: String, maxBytes: Int) async throws -> HTTPResponse {
        if path == "/mobile-assets.json" {
            manifestReads += 1
            let manifest = AssetManifest(schemaVersion: 1, protocolVersion: 1,
                offlineSchemaVersion: failure == .schema ? 3 : 2,
                buildId: AssetManifest.digest(Data((revision + (failure == .changed && manifestReads > 1 ? "changed" : "")).utf8)),
                files: paths.map { .init(path: $0, size: bytes($0).count, sha256: AssetManifest.digest(bytes($0)), contentType: "text/plain") })
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: try JSONEncoder().encode(manifest))
        }
        assetReads += 1
        if failure == .interrupted && assetReads == 3 { throw URLError(.networkConnectionLost) }
        if failure == .cancelled && assetReads == 3 { throw CancellationError() }
        return HTTPResponse(status: 200, body: failure == .corrupt ? Data("wrong".utf8) : bytes(path))
    }
}

final class CacheUpdateTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    deinit { try? FileManager.default.removeItem(at: root) }
    private func baseline() async throws -> (AssetCache, PreparedUI) {
        let cache = AssetCache(root: root)
        let first = try await cache.prepare(client: AssetFixture("first")) { _, _ in }
        try await cache.confirm(first)
        return (cache, first)
    }

    @Test func freshProfileDirectoryWithoutTrailingSlashCanActivateOnlyItsOwnUI() async throws {
        let path = root.appendingPathComponent("profiles/new/ui").path
        let cache = AssetCache(root: URL(fileURLWithPath: path, isDirectory: false))
        let ui = try await cache.prepare(client: AssetFixture("fresh")) { _, _ in }
        #expect(try await cache.load()?.directory == ui.directory)
        let other = AssetCache(root: root.appendingPathComponent("profiles/other/ui", isDirectory: true))
        do { try await other.activate(ui); Issue.record("Accepted another profile's UI") } catch {}
        let restarted = AssetCache(root: URL(fileURLWithPath: path, isDirectory: true))
        #expect(try await restarted.load()?.directory == ui.directory)
    }

    @Test func updateKeepsEachGenerationCoherentAndRecoversAfterRestart() async throws {
        let (cache, first) = try await baseline()
        let next = try await cache.stage(client: AssetFixture("second")) { _, _ in }
        try await cache.confirm(first) // A late startup callback cannot delete a staged update.
        #expect(FileManager.default.fileExists(atPath: next.directory.path))
        #expect(try await cache.load()?.directory == first.directory)
        #expect(try Data(contentsOf: first.directory.appendingPathComponent("reader/index.html")) == Data("first /reader/index.html".utf8))
        try await cache.activate(next)
        #expect(try await cache.load()?.directory == next.directory)
        #expect(try await cache.previous()?.directory == first.directory)
        #expect(try await cache.needsConfirmation())
        let restarted = AssetCache(root: root)
        #expect(try await restarted.needsConfirmation())
        let restored = try await restarted.rollback()
        #expect(restored.directory == first.directory)
        #expect(try await restarted.needsConfirmation() == false)
    }

    @Test func startupDetectsDamagedUpdateWithoutDamagingPrevious() async throws {
        let (cache, first) = try await baseline()
        let next = try await cache.prepare(client: AssetFixture("second")) { _, _ in }
        try Data("damaged".utf8).write(to: next.directory.appendingPathComponent("reader/index.html"))
        do { _ = try await cache.load(); Issue.record("Started a damaged generation") } catch { }
        #expect(try await cache.rollback().directory == first.directory)
        #expect(try await cache.load()?.manifest == first.manifest)
    }

    @Test func failedTransfersAndUnsupportedSchemaKeepWorkingGeneration() async throws {
        let (cache, first) = try await baseline()
        for failure in [AssetFixture.Failure.interrupted, .corrupt, .changed, .schema, .cancelled] {
            let remote = AssetFixture("second"); remote.failure = failure
            do { _ = try await cache.prepare(client: remote) { _, _ in }; Issue.record("Accepted failed update") } catch { }
            #expect(try await cache.load()?.directory == first.directory)
            if failure == .schema { #expect(remote.assetReads == 0) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix("stage-") })
        }
    }

    @Test func diskFullDuringFileOrPointerWritePreservesActiveGeneration() async throws {
        let (_, first) = try await baseline()
        for component in ["index.html", "selection.json"] {
            let cache = AssetCache(root: root) { data, url in
                if url.lastPathComponent == component { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
            do { _ = try await cache.prepare(client: AssetFixture("second")) { _, _ in }; Issue.record("Ignored disk-full failure") } catch { }
            #expect(try await cache.load()?.directory == first.directory)
        }
    }

    @Test func prototypePointerMigratesAndUnconfirmedVersionsNeverReplaceFallback() async throws {
        let (cache, first) = try await baseline()
        let legacyDirectory = root.appendingPathComponent(first.manifest.buildId, isDirectory: true)
        try FileManager.default.moveItem(at: first.directory, to: legacyDirectory)
        try FileManager.default.removeItem(at: root.appendingPathComponent("selection.json"))
        try JSONEncoder().encode(first.manifest.buildId).write(to: root.appendingPathComponent("active.json"))
        #expect(try await cache.load()?.directory == legacyDirectory)
        let second = try await cache.prepare(client: AssetFixture("second")) { _, _ in }
        let third = try await cache.prepare(client: AssetFixture("third")) { _, _ in }
        #expect(try await cache.previous()?.directory == legacyDirectory)
        try await cache.confirm(second) // A late acknowledgement cannot confirm a different active generation.
        #expect(try await cache.needsConfirmation())
        try await cache.confirm(third)
        #expect(try await cache.needsConfirmation() == false)
        #expect(try await cache.previous()?.directory == legacyDirectory)
    }
}
