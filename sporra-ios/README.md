# Sporra for iOS

Sporra's iPhone and iPad app is written in Swift, with system forms, switches,
colour pickers, navigation, calendars, sheets, and sharing. The map uses native
MapLibre and Mapbox views. Flutter is not required to build or run it.

Connect it to the same Sporra server and account you use on the web. Use server
version **0.136.0 or newer**. Your history and account preferences remain on your
server; this app does not require a separate backend or database migration.

## Run it

Open **`Sporra.xcodeproj`**, select the **Sporra** scheme and an iPhone or iPad
simulator, and press **⌘R**. Xcode downloads the pinned map SDK packages on the
first build. Install an iOS simulator runtime in Xcode's Settings → Components
if no simulator destinations are available.

For a physical iPhone, select your Apple development team in Signing &
Capabilities, enable Developer Mode on the phone, and run the same scheme.
The bundle identifier remains `com.zhekch.sporra`, so this replaces the previous
iOS web-view app. The older Flutter preview can remain installed alongside it.

Enter your server address and account credentials on the sign-in screen. For a
server running on your Mac, the simulator can use `http://127.0.0.1:PORT`.
Physical devices need an address reachable from the phone. Use HTTPS for a
remote server; local networking is allowed. Registration follows your server's
existing registration policy.

## Your map

The menu opens appearance, activity, trip, statistics, and settings screens.
Search finds places, activities, and trips; Calendar selects recorded days.
Day and trip tracks have previous/next controls. Activity cards show the
server's speed and elevation readings, with a graph you can drag to inspect a
point on the map. Overlapping activities offer a picker.

Appearance includes automatic detail, finest cells, country fills, visited
colours, heat modes, and opacity. The map supports satellite imagery, rotation,
and tilt. Add a public Mapbox token under Settings → Map layers to use Mapbox
3D and satellite, with automatic, day, or night lighting. Free basemaps work
without a token.

Railways, airport categories, and waymarked trails are available under Reference
layers. Enable Editing to paint or erase with the brush, clear a region, and
undo. Activities can be renamed, reclassified, deleted, and restored with Undo.

Settings includes reviewed file imports, Komoot links, source management,
Strava authorization, Home Assistant devices and schedules, and account
controls. Administrators can schedule and download server backups and inspect
the user list. The system share sheet exports the current map snapshot.

To set home, search for a place, hold its result, and choose **Set as home**.
Trips and statistics continue to be calculated by your server.

## Offline use

After signing in once with a connection, opening the app restores your saved
account and preferences immediately. It checks the server in the background;
a failed connection keeps you on the map with an **Offline** indicator. An
expired session keeps your saved map available and offers **Sign in to sync**.
Only explicit sign-out removes the saved account and its private offline data.

The app saves viewed content and downloads visits at every detail level, activity
lines, calendar days, trips, and statistics in the background. Settings → Offline
access shows download progress and lets you refresh that data. Saved activity
cards, day tracks, searches, and other details remain browsable offline; content
that has not been downloaded says so. Offline storage is bounded, so sufficiently
large histories can evict older responses. Let the offline download finish
before relying on a newly signed-in account away from your server.

Previously viewed basemap tiles use the map SDK's local cache. Tiles for new
areas need internet access. Offline display uses the native 2D map, with a plain
background if the basemap is unavailable; your saved visits and activity lines
still render. This does not download every street or satellite tile worldwide.

Appearance/account preference changes made offline are saved locally and synced
after reconnecting. Imports, map edits, activity changes, and server sync require
a connection. The phone's existing background location queue continues recording
offline and uploads when it can. Reconnection is checked on foreground entry,
periodically while open, or with **Retry**. Clearing the map cache removes offline
responses but retains the saved account.

## Recording and photographs

Settings → Import & sync → **This iPhone** controls background location
recording, accuracy, the device name, Apple Health workouts, and photo-location
sync. Records stay queued until the server accepts them. iOS permissions and
background execution limits still apply; the simulator needs configured
location, Health, or photo data to exercise these features.

**Photographs on this iPhone** in the map menu displays local geotagged photos.
Tap a photo marker to open the native gallery, including video playback.
Selecting a day or trip filters photos to that period. Browsing photos and
syncing their locations are separate switches. Images and videos are never
uploaded.

The app supports iOS 16 and later. Implementation and verification details are
in [ARCHITECTURE.md](../ARCHITECTURE.md#native-swift-ios-interface).
