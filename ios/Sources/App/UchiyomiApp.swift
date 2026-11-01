import SwiftUI
import WebKit

@main
struct UchiyomiApp: App {
    @StateObject private var model = ReaderModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ReaderView(model: model)
                .task { await model.restore() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.resume() } }
                }
        }
    }
}

private struct ReaderView: View {
    @ObservedObject var model: ReaderModel
    var body: some View {
        NavigationStack {
            Group {
                if let webView = model.webView {
                    ReaderWebView(view: webView, model: model)
                        .id(ObjectIdentifier(webView))
                } else {
                    ServerConnectionView(model: model)
                }
            }
            .navigationTitle(model.webView == nil ? "" : model.serverName)
            .toolbar(model.webView == nil ? .hidden : .visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.webView != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Servers") { model.showingServers = true }.disabled(model.busy)
                            Button("Reload reader") { Task { await model.reload() } }.disabled(model.busy)
                            Button("Downloads") { model.showDownloads() }.disabled(model.busy)
                            Button("Check for reader updates") { Task { await model.checkForUpdate() } }
                                .disabled(model.busy)
                            if model.canRecover {
                                Button("Restore previous reader") { Task { await model.recover() } }
                                    .disabled(model.busy)
                            }
                            Button("Download reader again") { Task { await model.downloadAgain() } }
                                .disabled(model.busy)
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.webView != nil {
                    VStack(spacing: 10) {
                        if let progress = model.progress { ProgressView(progress).font(.footnote) }
                        if model.updateAvailable {
                            Text("Reader update ready.").font(.footnote)
                            Button("Apply update") { Task { await model.applyUpdate() } }.disabled(model.busy)
                        }
                        if model.awaitingConfirmation {
                            Text("If the reader has opened correctly, keep this version.").font(.footnote)
                            Button("Keep this version") { Task { await model.confirmUI() } }.disabled(model.busy)
                        }
                        if let status = model.status {
                            HStack {
                                Text(status).font(.footnote)
                                Button("Dismiss") { model.status = nil }.font(.footnote)
                            }
                        }
                        if let error = model.error {
                            Text(error).font(.footnote)
                            HStack {
                                Button("Reload") { Task { await model.reload() } }
                                if model.canRecover {
                                    Button("Restore previous reader") { Task { await model.recover() } }
                                }
                            }.font(.footnote).disabled(model.busy)
                        }
                    }
                    .padding(model.progress != nil || model.updateAvailable || model.awaitingConfirmation || model.status != nil || model.error != nil ? 12 : 0)
                    .frame(maxWidth: .infinity).background(.regularMaterial)
                }
            }
        }
        .tint(Color(red: 124 / 255, green: 92 / 255, blue: 1))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showingServers) { ServerListView(model: model) }
    }
}

private struct ServerListView: View {
    @ObservedObject var model: ReaderModel
    @State private var removing: ServerProfile?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(model.profiles) { profile in
                    HStack {
                        Button { Task { await model.choose(profile) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.origin.host ?? "Uchiyomi").font(.headline)
                                    Text(profile.origin.absoluteString).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selectedID == profile.id { Image(systemName: "checkmark") }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button(role: .destructive) { removing = profile } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove \(profile.origin.host ?? "server")")
                    }.disabled(model.busy)
                }
                Button("Add server", systemImage: "plus") { Task { await model.addServer() } }.disabled(model.busy)
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle("Servers").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove this server from this device?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { profile in
                Button("Remove server", role: .destructive) { Task { await model.forget(profile) } }
                Button("Cancel", role: .cancel) {}
            } message: { profile in
                Text("This removes the saved session, downloads, and unsynced progress for \(profile.origin.absoluteString) from this device. The server library is kept.")
            }
        }.tint(Color(red: 124 / 255, green: 92 / 255, blue: 1)).preferredColorScheme(.dark)
    }
}

// Match the default web palette in web/app/globals.css; keep setup usable before any server is saved.
private struct ServerConnectionView: View {
    @ObservedObject var model: ReaderModel
    @FocusState private var addressFocused: Bool
    private let accent = Color(red: 124 / 255, green: 92 / 255, blue: 1)
    private let foreground = Color(red: 247 / 255, green: 247 / 255, blue: 251 / 255)
    private let muted = Color(red: 185 / 255, green: 185 / 255, blue: 198 / 255)

    private func connect() {
        addressFocused = false
        Task { await model.connect() }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        Image("BrandMark")
                            .resizable().scaledToFit().frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("uchiyomi").foregroundStyle(foreground)
                            Text(".").foregroundStyle(accent)
                        }
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .tracking(-1.5)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Uchiyomi")
                        Text("Your library, your way.")
                            .font(.subheadline).foregroundStyle(muted)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SERVER ADDRESS")
                                .font(.caption.weight(.medium)).tracking(1.2)
                                .foregroundStyle(muted)
                            TextField("https://books.example.com", text: $model.address)
                                .font(.body).foregroundStyle(foreground)
                                .textContentType(.URL).keyboardType(.URL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .submitLabel(.go).focused($addressFocused).onSubmit(connect)
                                .padding(16)
                                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16)
                                        .strokeBorder(addressFocused ? accent : .white.opacity(0.12), lineWidth: 1)
                                }
                                .disabled(model.progress != nil)
                                .accessibilityLabel("Server address")
                                .accessibilityIdentifier("serverAddress")
                        }
                        Button(action: connect) {
                            HStack(spacing: 10) {
                                if model.progress != nil { ProgressView().tint(.white) }
                                Text(model.progress == nil ? "Connect to server" : "Connecting…")
                                    .font(.body.weight(.semibold))
                                if model.progress == nil { Image(systemName: "arrow.right") }
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .foregroundStyle(.white)
                            .background(accent, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.progress != nil || model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                        .accessibilityIdentifier("prepareUI")
                        if let progress = model.progress {
                            Text(progress).font(.footnote).foregroundStyle(muted)
                                .frame(maxWidth: .infinity).accessibilityIdentifier("connectionProgress")
                        }
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(Color(red: 1, green: 0.6, blue: 0.6))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("connectionError")
                            if model.canRecover {
                                Button("Restore previous reader") { Task { await model.recover() } }
                                    .font(.footnote).disabled(model.busy)
                            }
                        }
                    }
                    .padding(24)
                    .background(Color(red: 11 / 255, green: 11 / 255, blue: 15 / 255), in: RoundedRectangle(cornerRadius: 24))
                    .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08), lineWidth: 1) }
                    if !model.profiles.isEmpty {
                        Button("Saved servers") { addressFocused = false; model.showingServers = true }
                            .disabled(model.busy)
                    }
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24).padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background {
            Color.black.ignoresSafeArea()
                .overlay {
                    RadialGradient(colors: [accent.opacity(0.15), .clear], center: UnitPoint(x: 0.5, y: 0.25), startRadius: 0, endRadius: 320)
                        .ignoresSafeArea()
                }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
    }
}

private struct ReaderWebView: UIViewRepresentable {
    let view: WKWebView
    let model: ReaderModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> WKWebView {
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: ReaderModel
        init(model: ReaderModel) { self.model = model }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard model.webView === webView, navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
            if model.isLocal(url) { webView.load(navigationAction.request) }
            else if navigationAction.navigationType == .linkActivated, ["https", "http", "mailto"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
            return nil
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard model.webView === webView, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if model.isLocal(url) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if navigationAction.navigationType == .linkActivated, ["https", "http", "mailto"].contains(url.scheme ?? "") {
                    UIApplication.shared.open(url)
                }
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { model.navigationFailed(webView, error: error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard model.webView === webView else { return }
            Task { await model.reload() }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { model.navigationFailed(webView, error: error) }
    }
}
