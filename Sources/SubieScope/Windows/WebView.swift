import CWebView2
import Foundation
import WinSDK

/// The browser view that fills the app's window and shows its page (Microsoft's WebView2,
/// which is part of Windows 11 and comes with Edge on Windows 10).
@MainActor
final class WebView {
    /// The view is there (true), or could not be made (false, with what went wrong).
    var onReady: ((Bool, String) -> Void)?
    /// A message from the page, as JSON text.
    var onMessage: ((String) -> Void)?

    private var view: OpaquePointer?
    private(set) var isReady = false

    /// Starts making the view inside `window`. The answer comes through `onReady`, later.
    func start(in window: HWND, loader: URL, dataFolder: URL) {
        try? FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        let context = Unmanaged.passUnretained(self).toOpaque()
        view = Self.wide(Desktop.path(loader)) { loader in
            Self.wide(Desktop.path(dataFolder)) { dataFolder in
                webview_create(UnsafeMutableRawPointer(window), loader, dataFolder, { context, ok, detail in
                    guard let context else { return }
                    let text = detail.map { String(cString: $0) } ?? ""
                    let view = Unmanaged<WebView>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated {
                        view.isReady = ok != 0
                        view.onReady?(ok != 0, text)
                    }
                }, { context, json in
                    guard let context, let json else { return }
                    let text = String(cString: json)
                    let view = Unmanaged<WebView>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { view.onMessage?(text) }
                }, context)
            }
        }
    }

    /// Serves a folder to the page as https://<host>/.
    func map(host: String, to folder: URL) {
        Self.wide(host) { host in Self.wide(Desktop.path(folder)) { webview_map_folder(view, host, $0) } }
    }

    func navigate(_ url: String) {
        Self.wide(url) { webview_navigate(view, $0) }
    }

    /// Hands a message to the page, as JSON text.
    func post(json: String) {
        guard isReady else { return }
        Self.wide(json) { webview_post_json(view, $0) }
    }

    func resize() { webview_resize(view) }
    func moved() { webview_moved(view) }
    func focus() { webview_focus(view) }
    func setBackground(red: UInt8, green: UInt8, blue: UInt8) { webview_set_background(view, red, green, blue) }
    func setDeveloperMode(_ on: Bool) { webview_set_developer_mode(view, on ? 1 : 0) }
    func openDeveloperTools() { webview_open_developer_tools(view) }

    func close() {
        isReady = false
        webview_destroy(view)
        view = nil
    }

    private static func wide<T>(_ text: String, _ body: (UnsafePointer<UInt16>) -> T) -> T {
        text.withCString(encodedAs: UTF16.self, body)
    }
}
