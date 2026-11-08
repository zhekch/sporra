import Combine
import Foundation

/// Shared server address for native screens and background sync.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    private init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    }
    var baseURL: URL? {
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? ServerAPI.address(serverURL)
    }
    func signOut() async {
        SyncClient.forgetSession()
        FixQueue.shared.clear()
        HealthSync.forgetAnchor()
        TrackingSettings.shared.status = TrackingSettings.SyncStatus()
    }
}
