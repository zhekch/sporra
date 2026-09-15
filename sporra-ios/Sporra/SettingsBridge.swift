import Combine
import Foundation
import WebKit

/// What the web app asks when it wants this app's own settings.
///
/// The map, the menu, backups, colours and login already live in the page, and
/// the page cannot wake a sleeping phone or name the server it is being hosted
/// by. Those answers sit in ``SettingsView``. The page used to reach them by a
/// tab bar; it now asks over this channel, the way it asks for photographs, and
/// the host puts the same screen in front of the map.
///
/// Which is also why the row exists **only in the app**. In a browser the
/// handler is simply not there, `src/personal-ui.js` sees as much, and the row
/// is left out of Personal rather than shown as a door that opens nothing.
///
/// The unconfigured page — before there is a server to load — presses the same
/// door from Swift rather than from JavaScript, so there is one presentation
/// rather than two.
@MainActor
final class SettingsBridge: NSObject, ObservableObject, WKScriptMessageHandlerWithReply {

    /// The name the page knows this by, and the whole of how it detects that
    /// this build can be asked. Changing it means changing `appSettingsHost()`
    /// in src/personal-ui.js.
    static let name = "sporraSettings"

    static let shared = SettingsBridge()

    /// The native settings screen is up. Bound by `ContentView` to a sheet, so
    /// the page asking and the unconfigured button press are the same door.
    @Published var isPresented = false

    private override init() { super.init() }

    func open() {
        isPresented = true
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let body = message.body as? [String: Any] ?? [:]
        switch body["ask"] as? String {
        case "open":
            open()
            replyHandler(["ok": true], nil)
        default:
            // A reply rather than an error, for the reason `PhotoBridge` gives:
            // a page asking something this build has never heard of is a new
            // site and an old app, which is a situation to report.
            replyHandler(["ok": false, "error": "unknown"], nil)
        }
    }
}
