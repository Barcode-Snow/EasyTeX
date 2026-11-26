import SwiftUI
import WebKit

/// Owns the WKWebView that hosts Monaco and translates between Swift and the page (Resources/editor/easytex.js).
/// The page is served through a custom `easytex://` scheme so Monaco's web worker has a proper same-origin URL.
@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKURLSchemeHandler {
    private(set) var webView: WKWebView!
    private var ready = false
    private var queue: [String] = []
    var onMessage: (([String: Any]) -> Void)?

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(self, forURLScheme: "easytex")
        config.userContentController.add(self, name: "easytex")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isInspectable = true              // Safari ▸ Develop menu can inspect the editor
        webView = view
        view.load(URLRequest(url: URL(string: "easytex://app/index.html")!))
    }

    // MARK: Resources

    static var resourceRoot: URL {
        let bundled = Bundle.main.resourceURL!.appendingPathComponent("editor")
        #if DEBUG
        // Running from Xcode or `swift run` (no app bundle): use <repo>/Resources/editor.
        // Debug only, so release builds don't contain the path of the machine they were built on.
        if !FileManager.default.fileExists(atPath: bundled.path) {
            return URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/editor")
        }
        #endif
        return bundled
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "ttf": return "font/ttf"
        case "woff2": return "font/woff2"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        var rel = url.path
        if rel.isEmpty || rel == "/" { rel = "/index.html" }
        let root = Self.resourceRoot.standardizedFileURL
        let file = root.appendingPathComponent(String(rel.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.path), let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let headers = ["Content-Type": Self.mimeType(for: file.pathExtension),
                       "Content-Length": "\(data.count)",
                       "Access-Control-Allow-Origin": "*"]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    // MARK: Page → Swift

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" {
            ready = true
            for js in queue { webView.evaluateJavaScript(js, completionHandler: nil) }
            queue.removeAll()
        }
        onMessage?(body)
    }

    // MARK: Swift → page

    private func call(_ js: String) {
        if ready { webView.evaluateJavaScript(js, completionHandler: nil) } else { queue.append(js) }
    }

    private static func literal(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    func open(path: String, text: String) { call("easytex.open(\(Self.literal(path)), \(Self.literal(text)))") }
    func close(path: String) { call("easytex.close(\(Self.literal(path)))") }
    func reload(path: String, text: String) { call("easytex.reload(\(Self.literal(path)), \(Self.literal(text)))") }
    func markSaved(_ paths: [String]) { if !paths.isEmpty { call("easytex.markSaved(\(Self.json(paths)))") } }
    func reveal(path: String, line: Int, column: Int) { call("easytex.reveal(\(Self.literal(path)), \(line), \(column))") }
    func setMarkers(path: String, items: [[String: Any]]) { call("easytex.setMarkers(\(Self.literal(path)), \(Self.json(items)))") }
    func clearMarkers() { call("easytex.clearMarkers()") }
    func setTheme(dark: Bool) { call("easytex.setTheme(\(dark))") }
    func setOptions(_ options: [String: Any]) { call("easytex.setOptions(\(Self.json(options)))") }

    /// Unsaved buffers as (file, text) pairs.
    func dirtyFiles(_ completion: @escaping ([(URL, String)]) -> Void) {
        guard ready else { completion([]); return }
        webView.evaluateJavaScript("easytex.dirtyFiles()") { result, _ in
            var items: [(URL, String)] = []
            if let json = result as? String,
               let data = json.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                for entry in array {
                    if let path = entry["path"], let text = entry["text"] {
                        items.append((URL(fileURLWithPath: path), text))
                    }
                }
            }
            completion(items)
        }
    }
}

struct EditorWebView: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeNSView(context: Context) -> WKWebView { state.editor.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
