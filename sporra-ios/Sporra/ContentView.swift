// `Combine` explicitly — this target turns on MemberImportVisibility, so a
// transitive import does not lend its members, and `onReceive` wants a publisher.
import Combine
import SwiftUI
import UIKit

/// The map, and a door into the little this app knows that the site does not.
///
/// The map is the web app — all of it, unmodified. The menu, the import dialogs,
/// the sync connectors, statistics and backups already work and already have
/// their own login; the phone hosts them rather than replacing them.
///
/// Settings is the handful of things only this app can answer: which server to
/// open, how this phone records where it has been, and how to forget both. The
/// second of those is not a duplicate of anything on the site — it is the one
/// setting that *could not* live on the server, because a schedule stored there
/// cannot wake a sleeping phone.
///
/// It used to be a second tab. A tab bar under a full-bleed map is a strip the
/// page then has to climb over, and the door belongs with the rest of Settings
/// anyway: Personal, at the top, labelled App settings, which the page asks
/// this host to open. See ``SettingsBridge``.
///
/// Before there is a server, there is no page to put that row on. The setup
/// screen is the same card the site uses for Settings, with a sentence and a
/// button, because the only thing the app can do yet is point at an address.
///
/// The derived data behind all of it — trips, coverage, the calendar — is worked
/// out once by the server (`server/derive.js`), so this phone and a laptop
/// cannot disagree about what they show.
struct ContentView: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var tracking = TrackingSettings.shared
    @StateObject private var host = SettingsBridge.shared

    var body: some View {
        Group {
            if let url = settings.baseURL {
                // Edge to edge: the map runs under the status bar, which is how
                // a map should look. The buttons stay clear of it because the
                // controller hands the page its own safe area — see
                // `WebViewController.pushSafeArea`. Ignoring the safe area here
                // is what gives that controller a view the size of the screen
                // *and* a correct `safeAreaInsets` describing what covers it.
                WebPanel(url: url, reloadToken: settings.reloadToken)
                    .ignoresSafeArea()
            } else {
                SetupPage { host.open() }
            }
        }
        .environmentObject(settings)
        .environmentObject(tracking)
        .sheet(isPresented: $host.isPresented) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(tracking)
        }
        // Leaving is the best moment there is to push: the queue is as full as
        // it is going to get, and the app is about to stop being handed any
        // runtime it did not ask for. The notification rather than `scenePhase`
        // because the one-argument `onChange` this deployment target still needs
        // is deprecated, and the two-argument one wants iOS 17.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            Task { await SyncClient.shared.flush(force: true) }
        }
        // The site is dark — its login card, its menu, and three of its four
        // basemaps. A sheet following the system into light mode puts a white
        // form over all of that, which reads as a page belonging to some other
        // app. Fixed rather than adaptive, because the thing it sits against is
        // fixed too.
        .preferredColorScheme(.dark)
    }
}

/// Before there is a server to open. Styled after the site's own settings card
/// rather than after a system empty state, because this *is* settings: the only
/// thing the app can do yet is point at an address, and the button that does
/// that should look like the door it is, not like an error.
private struct SetupPage: View {
    let onOpen: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.078, blue: 0.102)
            VStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings")
                        .font(.system(size: 17, weight: .bold))
                        .tracking(0.2)
                    Text("This app hosts the map you already use. Open settings to add the address of the server you run.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineSpacing(2.4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    Button("Open settings", action: onOpen)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.02, green: 0.071, blue: 0.122))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            Color(red: 0.376, green: 0.675, blue: 1.0),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .padding(.top, 22)
                }
                .padding(EdgeInsets(top: 22, leading: 22, bottom: 18, trailing: 22))
                .background {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                        }
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 400)
                Spacer(minLength: 0)
            }
        }
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
