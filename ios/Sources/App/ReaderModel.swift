import SwiftUI
import WebKit

@MainActor
final class ReaderModel: ObservableObject {
    @Published var address = ""
    @Published var progress: String?
    @Published var error: String?
    @Published var status: String?
    @Published var webView: WKWebView?
    @Published var serverName = "Uchiyomi"
    @Published var busy = false
    @Published var updateAvailable = false
    @Published var awaitingConfirmation = false
    @Published var canRecover = false
    @Published var profiles: [ServerProfile] = []
    @Published var selectedID: UUID?
    @Published var showingServers = false
    @Published var addingServer = false
    private var profile: ServerProfile?
    private var gateway: Gateway?
    private var client: RemoteClient?
    private var cache: AssetCache?
    private var activeUI: PreparedUI?
    private var stagedUI: PreparedUI?
    private var startupTask: Task<Void, Never>?
    private var readerID = UUID()
    private var restored = false
    private let root: URL
    private lazy var store = ProfileStore(root: root)
    private var catalog = ProfileStore.Catalog()

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Uchiyomi", isDirectory: true)) {
        self.root = root
    }

    private func save(_ updated: ProfileStore.Catalog) throws {
        try store.save(updated)
        catalog = updated; profiles = updated.profiles; selectedID = updated.selectedID
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        do {
            catalog = try store.load(); profiles = catalog.profiles; selectedID = catalog.selectedID
            if let saved = catalog.profiles.first(where: { $0.id == catalog.selectedID }) {
                profile = saved; address = saved.origin.absoluteString
                await open(saved, prepare: false)
            }
        } catch { self.error = error.localizedDescription }
    }
    func connect() async {
        guard !busy else { return }
        do {
            let origin = try ServerProfile.parse(address)
            let selected = try store.profile(for: origin, in: catalog)
            if !catalog.profiles.contains(where: { $0.id == selected.id }) {
                var updated = catalog
                updated.profiles.append(selected)
                try save(updated)
            }
            await open(selected, prepare: true)
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    private func stopReader() async -> Bool {
        readerID = UUID(); activeUI = nil
        startupTask?.cancel(); startupTask = nil
        weak var retired = webView
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil; webView = nil
        client?.cancel()
        await gateway?.stop(); gateway = nil
        client = nil
        // SwiftUI and pending WebKit callbacks may retain the view until the next run-loop turn.
        // WebKit requires it to be released before its persistent store can be removed.
        for _ in 0..<50 {
            if retired == nil { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return retired == nil
    }
    private func open(_ selected: ServerProfile, prepare: Bool, location: URL? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await replaceReader(selected, prepare: prepare, location: location)
    }
    // Callers hold busy across the entire transition, including cache activation/rollback.
    private func replaceReader(_ selected: ServerProfile, prepare: Bool, location: URL? = nil) async {
        precondition(busy)
        error = nil; status = nil; progress = "Opening your library…"
        defer { progress = nil }
        await stopReader()
        profile = selected; address = selected.origin.absoluteString
        updateAvailable = false; stagedUI = nil; awaitingConfirmation = false
        let cache = AssetCache(root: store.directory(for: selected).appendingPathComponent("ui"))
        self.cache = cache
        canRecover = (try? await cache.previous()) != nil
        do {
            let remote = try RemoteClient(origin: selected.origin, vault: KeychainCookieVault(profileID: selected.id))
            client = remote
            let ui: PreparedUI
            if prepare {
                progress = "Checking server…"
                let response = try await remote.fetch("/auth/config", maxBytes: 64 * 1024)
                try ServerCompatibility.validate(response)
                ui = try await cache.prepare(client: remote) { [weak self] count, total in
                    await MainActor.run { self?.progress = "Saving for offline use: \(count) of \(total)" }
                }
            } else {
                guard let saved = try await cache.load() else { throw ClientError.invalid("Connect to this server once to save the app for offline use.") }
                ui = saved
            }
            let gateway = Gateway(profile: selected, ui: ui, client: remote)
            try await gateway.start()
            self.gateway = gateway; profile = selected; activeUI = ui
            var updated = catalog
            updated.selectedID = selected.id
            try save(updated)
            canRecover = (try? await cache.previous()) != nil
            let pending = try await cache.needsConfirmation()
            awaitingConfirmation = pending && ui.manifest.startupCheckVersion != 1
            let readerID = self.readerID
            let view = try await NativeWebView.make(profile: selected, policy: gateway.policy) { [weak self] in
                Task { await self?.confirmUI(readerID: readerID) }
            }
            serverName = selected.origin.host ?? "Uchiyomi"
            webView = view
            addingServer = false; showingServers = false
            // Start at the web app's home page; its auth state handles offline fallback.
            view.load(URLRequest(url: location ?? selected.localOrigin))
            if pending && ui.manifest.startupCheckVersion == 1 {
                startupTask = Task { [weak self, weak view] in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    guard let self, self.webView === view else { return }
                    self.error = "The saved app did not finish starting. Reload it, restore the previous version, or download it again."
                }
            }
        } catch {
            await stopReader()
            self.error = ClientError.connectionMessage(error)
        }
    }
    func confirmUI() async {
        guard !busy else { return }
        await confirmUI(readerID: readerID)
    }
    private func confirmUI(readerID: UUID) async {
        guard self.readerID == readerID, let cache, let ui = activeUI else { return }
        do {
            try await cache.confirm(ui)
            guard self.readerID == readerID else { return }
            startupTask?.cancel(); startupTask = nil
            awaitingConfirmation = false; error = nil
        } catch {
            guard self.readerID == readerID else { return }
            self.error = "Could not confirm this app version: \(error.localizedDescription)"
        }
    }
    func checkForUpdate() async {
        guard !busy, let client, let cache, let ui = activeUI else { return }
        busy = true; error = nil; status = nil; progress = "Checking for an update…"
        defer { busy = false; progress = nil }
        do {
            let latest = try AssetManifest.decodeResponse(await client.fetch("/mobile-assets.json", maxBytes: 4 * 1024 * 1024))
            if latest == ui.manifest { status = "The saved app is up to date."; return }
            let staged = try await cache.stage(client: client) { [weak self] count, total in
                await MainActor.run { self?.progress = "Downloading update: \(count) of \(total)" }
            }
            stagedUI = staged; updateAvailable = true
        } catch { self.error = "Update could not be saved. Your current app is still available. \(error.localizedDescription)" }
    }
    func applyUpdate() async {
        guard !busy, let profile, let cache, let stagedUI else { return }
        busy = true
        defer { busy = false }
        let location = webView?.url
        do {
            try await cache.activate(stagedUI)
            await replaceReader(profile, prepare: false, location: location)
        } catch { self.error = error.localizedDescription }
    }
    func recover() async {
        guard !busy, let profile, let cache else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await cache.rollback()
            await replaceReader(profile, prepare: false)
        } catch { self.error = error.localizedDescription }
    }
    func downloadAgain() async {
        guard let profile else { await connect(); return }
        await open(profile, prepare: true)
    }
    func choose(_ selected: ServerProfile) async {
        guard !busy, profiles.contains(selected) else { return }
        showingServers = false; addingServer = false
        await open(selected, prepare: false)
    }
    func addServer() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await stopReader()
        profile = nil; activeUI = nil; stagedUI = nil; cache = nil
        address = ""; error = nil; status = nil; canRecover = false
        updateAvailable = false; awaitingConfirmation = false
        showingServers = false; addingServer = true
    }
    /// Call only after the user confirms deletion in the server list.
    func forget(_ forgotten: ServerProfile) async {
        guard !busy, profiles.contains(forgotten) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if profile?.id == forgotten.id {
                guard await stopReader() else { throw ClientError.invalid("The reader is still closing. Please try again.") }
                profile = nil; cache = nil; activeUI = nil; stagedUI = nil
                canRecover = false; updateAvailable = false; awaitingConfirmation = false
                address = ""; status = nil
            }
            // Remove credentials before files; keep a failed removal listed so it can be retried.
            try KeychainCookieVault(profileID: forgotten.id).remove()
            try await NativeWebView.removeStore(for: forgotten.id)
            let directory = store.directory(for: forgotten)
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            var updated = catalog
            updated.profiles.removeAll { $0.id == forgotten.id }
            if updated.selectedID == forgotten.id { updated.selectedID = nil }
            try save(updated)
        } catch { self.error = "Could not finish removing this server. Retry to remove its remaining local data. \(error.localizedDescription)" }
    }
    func resume() async {
        guard !busy, let gateway else { return }
        let readerID = self.readerID
        do { try await gateway.start() } catch {
            guard self.readerID == readerID else { return }
            self.error = "Cannot restart the reader: \(error.localizedDescription)"
        }
    }
    func reload() async {
        guard !busy, let view = webView else { return }
        error = nil
        await resume()
        guard !busy, webView === view else { return }
        view.reload()
    }
    func showDownloads() {
        guard !busy, let profile else { return }
        webView?.load(URLRequest(url: profile.localOrigin.appendingPathComponent("downloads/")))
    }
    func isLocal(_ url: URL) -> Bool {
        guard let profile else { return false }
        return url.scheme == "http" && url.host == "localhost" && url.port == Int(profile.port)
    }
    func navigationFailed(_ view: WKWebView, error: Error) {
        guard webView === view, (error as NSError).code != NSURLErrorCancelled else { return }
        self.error = error.localizedDescription
    }
}
