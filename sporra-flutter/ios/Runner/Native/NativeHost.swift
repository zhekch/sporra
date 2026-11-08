import AuthenticationServices
import Flutter
import Foundation
import Photos
import AVKit
import UIKit

@MainActor
final class NativeHost: NSObject, SporraNative, ASWebAuthenticationPresentationContextProviding {
    private var authentication: ASWebAuthenticationSession?
    private var library: [PhotoLibrary.Located] = []
    private func json(_ value: Any) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
    func settings() throws -> String {
        let s = TrackingSettings.shared
        return json(["server": AppSettings.shared.serverURL, "cadence": s.cadence.rawValue,
                     "precision": s.precision.rawValue, "health": s.syncWorkouts,
                     "photos": s.syncPhotos, "deviceName": s.deviceName,
                     "pending": FixQueue.shared.count, "error": s.status.lastError ?? "",
                     "workouts": s.status.workoutsSent, "photoCount": s.status.photosSent])
    }
    func configure(json text: String) async throws -> String {
        let v = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        let s = TrackingSettings.shared
        if let server = v["server"] as? String {
            if server != AppSettings.shared.serverURL { await AppSettings.shared.signOut() }
            AppSettings.shared.serverURL = server
        }
        if let n = v["cadence"] as? Int, let c = TrackingSettings.Cadence(rawValue: n) { s.cadence = c }
        if let p = v["precision"] as? Int { s.precision = TrackingSettings.Precision.resolved(p) }
        if let health = v["health"] as? Bool { s.syncWorkouts = health }
        if let photos = v["photos"] as? Bool { s.syncPhotos = photos }
        if let name = v["deviceName"] as? String { s.deviceName = name }
        return try settings()
    }
    func sync() async throws -> String {
        await SyncClient.shared.flush(force: true)
        if TrackingSettings.shared.syncWorkouts { await HealthSync.shared.sync() }
        if TrackingSettings.shared.syncPhotos { await PhotoSync.shared.scan() }
        return try settings()
    }
    func signOut() async throws { await AppSettings.shared.signOut(); library = [] }
    func photos() async throws -> String {
        _ = await PhotoLibrary.authorize()
        library = await Task.detached { PhotoLibrary.located() }.value
        return json(library.enumerated().map { i, p in
            ["index": i, "lng": p.lng, "lat": p.lat, "time": p.t, "video": p.isVideo] as [String: Any]
        })
    }
    func thumbnail(index: Int64, pixels: Int64) async throws -> FlutterStandardTypedData {
        guard library.indices.contains(Int(index)), let image = await PhotoLibrary.jpeg(id: library[Int(index)].id, px: min(4096, max(64, Int(pixels)))) else {
            throw PigeonError(code: "photo", message: "The photo could not be loaded.", details: nil)
        }
        return FlutterStandardTypedData(bytes: image.data)
    }
    func playVideo(index: Int64) async throws {
        guard library.indices.contains(Int(index)), let item = await PhotoLibrary.playerItem(id: library[Int(index)].id), let top = topController() else {
            throw PigeonError(code: "video", message: "The video could not be loaded.", details: nil)
        }
        let player = VideoPlayerController()
        player.player = AVPlayer(playerItem: item)
        top.present(player, animated: true) { player.player?.play() }
    }
    func saveImage(png: FlutterStandardTypedData) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PigeonError(code: "permission", message: "Allow saving pictures in iOS Settings.", details: nil)
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png.data, options: nil)
        }
    }
    func authenticate(url text: String) async throws -> String {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme ?? "") else {
            throw PigeonError(code: "url", message: "Invalid authorization address.", details: nil)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "sporra-flutter") { [weak self] url, error in
                self?.authentication = nil
                if let url { continuation.resume(returning: url.absoluteString) }
                else { continuation.resume(throwing: error ?? PigeonError(code: "oauth", message: "Authorization was cancelled.", details: nil)) }
            }
            session.presentationContextProvider = self
            authentication = session
            if !session.start() {
                authentication = nil
                continuation.resume(throwing: PigeonError(code: "oauth", message: "Authorization could not be opened.", details: nil))
            }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        topController()?.view.window ?? ASPresentationAnchor()
    }
    private func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
