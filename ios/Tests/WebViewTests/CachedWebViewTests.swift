import XCTest
import WebKit
@testable import Uchiyomi

private struct EmptyVault: CookieVault {
    func read() -> Data? { nil }
    func write(_ data: Data) {}
}

// Uses the real exported frontend in a test bundle. These files are never part of Uchiyomi.app.
@MainActor
final class CachedWebViewTests: XCTestCase {
    func testPreparedReaderWithUnavailableServer() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "out", withExtension: nil))
        let manifest = try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: directory.appendingPathComponent("mobile-assets.json")))
        try manifest.validate()
        let profile = ServerProfile(id: UUID(), origin: URL(string: "https://127.0.0.1:9")!, port: UInt16.random(in: 49152...60999))
        let client = try RemoteClient(origin: profile.origin, vault: EmptyVault())
        let gateway = Gateway(profile: profile, ui: PreparedUI(directory: directory, manifest: manifest), client: client)
        try await gateway.start()
        let host = UIViewController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        var web: WKWebView? = try await NativeWebView.make(profile: profile, policy: gateway.policy)
        func mount(_ view: WKWebView) { view.frame = host.view.bounds; host.view.addSubview(view) }
        mount(web!)
        defer {
            web?.stopLoading(); web?.removeFromSuperview(); web = nil
            window.isHidden = true; client.cancel()
        }
        do {
            // A non-reader page establishes the real local origin before fixture data is seeded.
            web!.load(URLRequest(url: profile.localOrigin.appendingPathComponent("downloads/")))
            try await waitFor(web!, "document.readyState === 'complete' && !!window.uchiyomiNative")
            let cookieVisible = try await web!.evaluateJavaScript("document.cookie.includes('uchiyomi_gateway')") as? Bool
            XCTAssertEqual(cookieVisible, false, "The local capability must remain HttpOnly")
            _ = try await web!.callAsyncJavaScript(Self.seed, arguments: [:], in: nil, contentWorld: .page)
            // Tear down the web view and listener, then recreate both at the exact saved origin/store.
            web!.stopLoading(); web!.removeFromSuperview(); web = nil
            await gateway.stop()
            try await gateway.start()
            web = try await NativeWebView.make(profile: profile, policy: gateway.policy)
            mount(web!)
            web!.load(URLRequest(url: profile.localOrigin.appendingPathComponent("downloads/")))
            try await waitFor(web!, "document.body.innerText.includes('Offline fixture')")
            let registrations = try await web!.callAsyncJavaScript("return (await navigator.serviceWorker.getRegistrations()).length", arguments: [:], in: nil, contentWorld: .page) as? Int
            XCTAssertEqual(registrations, 0, "The native host registered a service worker")
            // Both reader routes/chunks have never been visited. The upstream port refuses connections.
            for book in ["fixture-1", "fixture-2"] {
                web!.load(URLRequest(url: URL(string: profile.localOrigin.absoluteString + "/reader/?book=" + book)!))
                try await waitFor(web!, "location.pathname === '/reader/' && new URL(location.href).searchParams.get('book') === '\(book)' && !document.body.innerText.includes('Loading chapter') && Array.from(document.images).some(i => i.src.startsWith('blob:') && i.complete && i.naturalWidth > 0)")
                let problem = try await web!.evaluateJavaScript("document.body.innerText.includes('Loading chapter')") as? Bool
                XCTAssertEqual(problem, false)
            }
            let attachment = XCTAttachment(image: window.screen.screenshotForTest(window: window))
            attachment.name = "Cached reader with unavailable server"
            attachment.lifetime = .keepAlways
            add(attachment)
            await gateway.stop()
        } catch {
            let text = try? await web?.evaluateJavaScript("document.body.innerText")
            XCTFail("Web view did not reach the offline reader: \(error). Page: \(String(describing: text))")
            await gateway.stop()
            throw error
        }
    }

    func testUIUpdateAndFailedStartupRecoveryPreserveOfflineData() async throws {
        let export = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "out", withExtension: nil))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AssetCache(root: root)
        let first = try await cache.prepare(client: ExportFixture(directory: export, revision: "first")) { _, _ in }
        let profile = ServerProfile(id: UUID(), origin: URL(string: "https://127.0.0.1:9")!, port: UInt16.random(in: 49152...60999))
        let client = try RemoteClient(origin: profile.origin, vault: EmptyVault())
        let host = UIViewController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.rootViewController = host; window.makeKeyAndVisible()
        var gateway: Gateway?
        var web: WKWebView?
        var ready = false
        func open(_ ui: PreparedUI) async throws {
            web?.stopLoading(); web?.removeFromSuperview(); web = nil
            await gateway?.stop()
            let next = Gateway(profile: profile, ui: ui, client: client)
            try await next.start(); gateway = next
            ready = false
            let view = try await NativeWebView.make(profile: profile, policy: next.policy) { ready = true }
            web = view; view.frame = host.view.bounds; host.view.addSubview(view)
            view.load(URLRequest(url: profile.localOrigin.appendingPathComponent("downloads/")))
        }
        func confirmReady(_ ui: PreparedUI) async throws {
            for _ in 0..<100 {
                if ready { try await cache.confirm(ui); return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw ClientError.invalid("The exported UI never acknowledged startup.")
        }
        defer {
            web?.stopLoading(); web?.removeFromSuperview(); window.isHidden = true; client.cancel()
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await open(first)
            try await confirmReady(first)
            _ = try await web!.callAsyncJavaScript(Self.seed, arguments: [:], in: nil, contentWorld: .page)
            _ = try await web!.callAsyncJavaScript("""
                const db = await new Promise((resolve,reject)=>{const r=indexedDB.open('yomi-offline',2);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
                const tx=db.transaction('outbox','readwrite');
                tx.objectStore('outbox').put({id:999,userId:'ios-fixture',bookId:'fixture-2',seriesId:'fixture-series',deviceId:'ios-test',page:2,completed:false,ts:1700000000000,tries:0});
                await new Promise((resolve,reject)=>{tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error)});db.close();return true;
                """, arguments: [:], in: nil, contentWorld: .page)
            let second = try await cache.stage(client: ExportFixture(directory: export, revision: "second")) { _, _ in }
            let stillFirst = try await cache.load()
            XCTAssertEqual(stillFirst?.directory, first.directory, "Downloading an update changed the running generation")
            try await cache.activate(second)
            try await open(second)
            try await confirmReady(second)
            try await waitFor(web!, "document.body.innerText.includes('Offline fixture')")
            let broken = try await cache.prepare(client: ExportFixture(directory: export, revision: "broken", broken: true)) { _, _ in }
            try await open(broken)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            XCTAssertFalse(ready, "A failed JavaScript startup acknowledged readiness")
            let stillPending = try await cache.needsConfirmation()
            XCTAssertTrue(stillPending)
            let recovered = try await cache.rollback()
            XCTAssertEqual(recovered.directory, second.directory)
            try await open(recovered)
            try await confirmReady(recovered)
            try await waitFor(web!, "document.body.innerText.includes('Offline fixture')")
            for book in ["fixture-1", "fixture-2"] {
                web!.load(URLRequest(url: URL(string: profile.localOrigin.absoluteString + "/reader/?book=" + book)!))
                try await waitFor(web!, "new URL(location.href).searchParams.get('book') === '\(book)' && !document.body.innerText.includes('Loading chapter') && Array.from(document.images).some(i=>i.src.startsWith('blob:') && i.complete && i.naturalWidth>0)")
            }
            let retained = try await web!.callAsyncJavaScript("""
                const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('yomi-offline',2);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
                const value=await new Promise((resolve,reject)=>{const r=db.transaction('outbox').objectStore('outbox').get(999);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
                db.close();return value?.userId==='ios-fixture' && value?.page===2 && value?.ts===1700000000000 && JSON.parse(localStorage.getItem('uchiyomi.offlineUser')).id==='ios-fixture';
                """, arguments: [:], in: nil, contentWorld: .page) as? Bool
            XCTAssertEqual(retained, true, "UI recovery changed account identity or queued progress")
            await gateway?.stop()
        } catch { await gateway?.stop(); throw error }
    }

    func testTwoServerProfilesWithSameAccountAndChapterIDsAndConfirmedRemoval() async throws {
        let export = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "out", withExtension: nil))
        let manifest = try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: export.appendingPathComponent("mobile-assets.json")))
        let basePort = UInt16.random(in: 49152...59998)
        let a = ServerProfile(id: UUID(), origin: URL(string: "https://127.0.0.1:9")!, port: basePort)
        let b = ServerProfile(id: UUID(), origin: URL(string: "https://127.0.0.1:10")!, port: basePort + 1)
        let host = UIViewController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.rootViewController = host; window.makeKeyAndVisible()
        var web: WKWebView?
        var gateway: Gateway?
        var client: RemoteClient?
        func close() async {
            weak var retired = web
            web?.stopLoading(); web?.removeFromSuperview(); web = nil
            client?.cancel(); client = nil
            await gateway?.stop(); gateway = nil
            for _ in 0..<50 {
                if retired == nil { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertNil(retired, "The old profile's WebKit view was not released before store removal")
        }
        func open(_ profile: ServerProfile) async throws {
            await close()
            let remote = try RemoteClient(origin: profile.origin, vault: EmptyVault()); client = remote
            let local = Gateway(profile: profile, ui: PreparedUI(directory: export, manifest: manifest), client: remote)
            try await local.start(); gateway = local
            let view = try await NativeWebView.make(profile: profile, policy: local.policy)
            web = view; view.frame = host.view.bounds; host.view.addSubview(view)
            view.load(URLRequest(url: profile.localOrigin.appendingPathComponent("downloads/")))
            try await waitFor(view, "document.readyState === 'complete' && !!window.uchiyomiNative")
        }
        let queueScript = """
            const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('yomi-offline',2);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
            const tx=db.transaction('outbox','readwrite');tx.objectStore('outbox').put({id:999,userId:'ios-fixture',bookId:'fixture-2',page,ts:1700000000000,deviceId:'ios-test',tries:0});
            await new Promise((resolve,reject)=>{tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error)});db.close();return true;
            """
        let inspectScript = """
            const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('yomi-offline',2);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
            const get=(store,key)=>new Promise((resolve,reject)=>{const r=db.transaction(store).objectStore(store).get(key);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
            const chapter=await get('chapters','ios-fixture:fixture-2');const queued=await get('outbox',999);db.close();return {title:chapter?.seriesTitle,page:queued?.page};
            """
        var stage = "seed and switch profiles"
        do {
            try await open(a)
            _ = try await web!.callAsyncJavaScript(Self.seed.replacingOccurrences(of: "Offline fixture", with: "Server A"), arguments: [:], in: nil, contentWorld: .page)
            _ = try await web!.callAsyncJavaScript(queueScript, arguments: ["page": 11], in: nil, contentWorld: .page)
            try await open(b)
            let empty = try await web!.evaluateJavaScript("localStorage.getItem('uchiyomi.offlineUser') === null") as? Bool
            XCTAssertEqual(empty, true, "A new profile inherited another server's identity")
            _ = try await web!.callAsyncJavaScript(Self.seed.replacingOccurrences(of: "Offline fixture", with: "Server B"), arguments: [:], in: nil, contentWorld: .page)
            _ = try await web!.callAsyncJavaScript(queueScript, arguments: ["page": 22], in: nil, contentWorld: .page)
            for (profile, title, page) in [(a, "Server A", 11), (b, "Server B", 22)] {
                try await open(profile)
                let data = try await web!.callAsyncJavaScript(inspectScript, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
                XCTAssertEqual(data?["title"] as? String, title)
                XCTAssertEqual(data?["page"] as? Int, page)
            }
            await close()
            stage = "remove A"; NSLog("Profile test: %@", stage)
            try await NativeWebView.removeStore(for: a.id)
            stage = "reopen removed A"; NSLog("Profile test: %@", stage)
            try await open(a)
            let removed = try await web!.evaluateJavaScript("localStorage.getItem('uchiyomi.offlineUser') === null") as? Bool
            XCTAssertEqual(removed, true)
            stage = "verify surviving B"; NSLog("Profile test: %@", stage)
            try await open(b)
            let surviving = try await web!.callAsyncJavaScript(inspectScript, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(surviving?["title"] as? String, "Server B")
            XCTAssertEqual(surviving?["page"] as? Int, 22)
            await close()
            stage = "cleanup A"; NSLog("Profile test: %@", stage)
            try await NativeWebView.removeStore(for: a.id)
            stage = "cleanup B"; NSLog("Profile test: %@", stage)
            try await NativeWebView.removeStore(for: b.id)
            window.isHidden = true
        } catch { await close(); window.isHidden = true; throw ClientError.invalid("\(stage): \(error)") }
    }

    private func waitFor(_ web: WKWebView, _ expression: String) async throws {
        for _ in 0..<150 {
            if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ClientError.invalid("Timed out waiting for: " + expression)
    }

    private static let seed = #"""
    localStorage.setItem('uchiyomi.offlineUser', JSON.stringify({v:1,id:'ios-fixture',username:'fixture',displayName:'Offline Tester',role:'admin',exp:Date.now()+86400000}));
    const db = await new Promise((resolve, reject) => {
      const req = indexedDB.open('yomi-offline', 2);
      req.onerror = () => reject(req.error);
      req.onupgradeneeded = () => {
        const d = req.result;
        if (!d.objectStoreNames.contains('chapters')) d.createObjectStore('chapters',{keyPath:'key'}).createIndex('byUser','userId');
        if (!d.objectStoreNames.contains('pages')) d.createObjectStore('pages');
        if (!d.objectStoreNames.contains('outbox')) d.createObjectStore('outbox',{keyPath:'id',autoIncrement:true});
      };
      req.onsuccess = () => resolve(req.result);
    });
    const tx = db.transaction(['chapters','pages'], 'readwrite');
    for (const n of [1,2]) {
      const bookId = 'fixture-'+n;
      tx.objectStore('chapters').put({key:'ios-fixture:'+bookId,userId:'ios-fixture',bookId,seriesId:'fixture-series',seriesTitle:'Offline fixture',title:'Chapter '+n,number:String(n),pageCount:2,readingDirection:'VERTICAL',totalBytes:300,savedAt:Date.now(),pages:[1,2].map(number=>({number,width:800,height:1200}))});
      for (const p of [1,2]) {
        const image = `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="1200"><rect width="800" height="1200" fill="${n===1?'#a7c7e7':'#c1e1c1'}"/><text x="60" y="150" font-size="48">Chapter ${n} / page ${p}</text></svg>`;
        tx.objectStore('pages').put(new Blob([image],{type:'image/svg+xml'}), 'ios-fixture:'+bookId+':'+p);
      }
    }
    await new Promise((resolve,reject)=>{tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error)});
    db.close();
    return true;
    """#
}

private extension UIScreen {
    func screenshotForTest(window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    }
}

private final class ExportFixture: AssetFetching {
    private let inventory: Data
    private let files: [String: Data]
    init(directory: URL, revision: String, broken: Bool = false) throws {
        let original = try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: directory.appendingPathComponent("mobile-assets.json")))
        var bytes: [String: Data] = [:]
        for asset in original.files {
            var data = try Data(contentsOf: directory.appendingPathComponent(String(asset.path.dropFirst())))
            if asset.path.hasSuffix(".html") { data.append(Data("<!-- \(revision) -->".utf8)) }
            if broken && asset.path.hasSuffix(".js") { data = Data("throw new Error('Test bootstrap failure');".utf8) }
            bytes[asset.path] = data
        }
        var manifest = AssetManifest(schemaVersion: 1, protocolVersion: 1, offlineSchemaVersion: 2,
            buildId: AssetManifest.digest(Data(revision.utf8)), files: original.files.map {
                .init(path: $0.path, size: bytes[$0.path]!.count, sha256: AssetManifest.digest(bytes[$0.path]!), contentType: $0.contentType)
            })
        manifest.startupCheckVersion = 1
        inventory = try JSONEncoder().encode(manifest); files = bytes
    }
    func assetResponse(_ path: String, maxBytes: Int) async throws -> HTTPResponse {
        if path == "/mobile-assets.json" { return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: inventory) }
        guard let data = files[path] else { return .message(404, "missing") }
        return HTTPResponse(status: 200, body: data)
    }
}
