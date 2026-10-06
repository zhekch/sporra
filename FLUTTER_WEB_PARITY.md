# Flutter / mobile web feature comparison

Audit date: 6 October 2026. Reference: the checked-in mobile web implementation,
not the older preview checklist. Target: Flutter 0.3.0+3 with server 0.133.0.

**Full parity has not been achieved.** A shared API proves identical data rules;
it does not prove identical screen layout, gestures, transitions or rendering.
“Present” below means the feature exists in both clients. “Partial” identifies a
specific remaining difference. “Missing” means Flutter does not implement it.
The verification section separates simulator evidence from source inspection.

## Map, ground and navigation

| Web feature | Flutter comparison |
|---|---|
| Dark basemap | Present: native CARTO Dark |
| Light basemap | Present: native CARTO Voyager |
| Terrain basemap | Present: shared server style; dark colour treatment |
| Satellite basemap | Present: shared Esri fallback style; token-backed Mapbox variant differs |
| Mapbox Standard 3D | Missing: MapLibre cannot render Standard style imports |
| Automatic sun / dawn / dusk lighting | Missing with the 3D engine |
| Snow modes and particles | Missing |
| Basemap token settings and validation | Missing |
| Camera pan, zoom, pitch, bearing | Present; native gesture physics differ |
| Three primary mobile buttons: search, menu, locate | Corrected: three vertical buttons |
| Compass only when rotated or tilted | Corrected: conditional compass |
| Locate and recenter | Present: native permission/location bridge; physical-device accuracy unverified |
| Scale bar and attribution | Present; native control styling differs |
| Saved viewport / restoration | Partial: preferences and session restore, persistent camera state differs |
| Control lift above open cards | Corrected: actual measured card height, animated lift |
| Controls hidden behind open menu | Corrected |
| Six hex detail levels and Auto camera ladder | Present: shared rollups, golden coordinate vectors |
| Explicit Region / Country | Present; World removed from the Flutter menu at user request; Auto retains continent rollup |
| Visited blob geometry, shaping, blur | Present: existing shared golden blob vectors |
| Single colour | Present: shared colour and opacity |
| Visits heat colouring | Present: shared aggregation and ramps |
| Source/type colouring | Present: shared source allocation |
| First-seen colouring / undated handling | Present: shared dates and ramps |
| Press active colouring mode again to hide ground | Partial: Flutter lacks the same toggle gesture |
| Separate dark/light accent, custom hex, opacity | Present |
| Region/country dissolved geometry | Present: shared area rendering |
| High-quality visible-country boundary LOD | Corrected: viewport-driven fine fetch and cache |
| Region borders | Both intentionally omit them: web SHOW_REGION_BORDERS=false |
| Continent visited-country count labels | Missing |
| Cell-to-cell crossfade | Present: native raster fade; timing is not fully matched |
| Raster-to-region / vector-level crossfade | Partial: region fills change without the complete web transition |
| Tap visited/unvisited ground | Corrected: immediate card from prefetched facts; server enriches details |
| Ground facts, counts, first/last visit, hidden-source filter | Present: shared summary rules |
| Geographic place-name enrichment | Present: asynchronous shared server lookup |
| Tap while data is unavailable | Partial: immediate loading card, then server result; cannot promise cached facts before loading |
| Cell/region selection highlight | Missing |
| Swipe place card away | Corrected: horizontal dismissal |
| Drag/reposition popups | Partial: Flutter sheets and cards use native dismissal; web drag behavior differs |

## Activities

| Web feature | Flutter comparison |
|---|---|
| Activity visibility toggle | Present |
| Per-sport visibility, colour and alpha | Present: account routeView preferences |
| Blank activity-type sentinel | Present: same shared key |
| Colour each route palette | Present: shared paletteFor |
| Reset activity appearance | Present |
| Randomise palette | Missing |
| Route core zoom widths and selected scale | Corrected: web width stops and 1.7 selected scale |
| Four phone glow rings, theme contrast and alpha | Corrected: concentric rings replace native blur |
| Finger-sized route hit tolerance | Corrected: 8px box around tap |
| Overlapping route chooser | Corrected: deduplicated route IDs, compact chooser; simulator verified |
| Tap inspection without automatically hiding other routes | Corrected: solo is explicit |
| Speed-coloured continuous line | Corrected: round caps/joins, zero simplification, web dark casing |
| Elevation-coloured line | Corrected: same shared metric geometry and ramp |
| Preserve real recording gaps | Present: shared route samples and segments |
| Activity summary / date / distance / average speed | Present: shared activity endpoint |
| Speed and elevation graphs | Present: shared graph readings; native graph renderer |
| Missing-metric empty states | Present |
| Graph drag selects map cursor | Present; simulator verified |
| Metric-line tap selects graph sample | Present; simulator verified |
| Previous/next activity, retain chosen metric | Present |
| Explicit solo / show all | Present; named workout banner can be swiped away, with previous/next arrows and no distance/date line; exact web solo-chip presentation differs |
| Zoom to activity | Present |
| Edit name, type, place, source | Present; source editing added in this change |
| Undo metadata edits | Missing |
| Delete activity and undo | Added: account-owned delete endpoint and restore from returned route |
| Route geometry thumbnail | Missing |
| External Komoot source link | Partial: stored by server but Flutter details do not expose it |
| Route-stack temporary colour / peek | Partial: shared temporary colours, grouped colour dots and map isolation added; row peek remains missing |
| Duplicate folding and show duplicates | Missing |
| Route list sorting: newest / longest | Added |
| Route list grouping: flat / app / activity | Added; exact vague-source group ordering remains different |
| Total activity distance / duration / longest | Present: shared activity statistics |
| Annual distance chart | Present: shared years including recorded-duration rules |

## Search, trips and calendar

| Web feature | Flutter comparison |
|---|---|
| Search places / regions / countries | Present: shared gazetteers |
| Search trip names and dates | Present: shared search rules |
| Search activities | Present |
| Ranked groups and empty-state trip list | Partial: Flutter uses one list and lacks web initial trip view |
| Search calendar button | Added |
| Month navigation | Added |
| Recorded-day markers / activity versus ground dots | Added: calendar reads account days |
| Continuous trip day pills | Added |
| Selected/today indicators | Added |
| Pick a day from calendar | Present |
| Search-result place pin | Missing |
| Trip list and geographic framing | Present |
| Yellow trip/day points and connecting lines | Corrected: shared trackFC and web yellow style |
| Break links for duplicate/missing timestamps and long gaps | Present: shared trackFC, tested |
| Trip/day chip label and clear | Named banner with trip context and refined typography; trip swipes horizontally to clear, day swipes upward to clear and horizontally to step |
| Previous/next recorded day and swipe stepping | Added |
| Trip chip drill down to days | Added |
| Trip naming and reset derived name | Added: shared account preference keys |
| Hide trip / show put-away trips | Added |
| Trip/day associated activities | Partial: endpoints supply them, activity navigation is not fully scoped |
| Date-filtered local photo pins / gallery | Corrected: full calendar-day bounds, exclusive end |
| Track-span selection and painting | Missing |

## Editing and reference layers

| Web feature | Flutter comparison |
|---|---|
| Enter/leave visited-ground editing | Present |
| Paint / erase strokes and brush sizes | Present: shared brush geometry |
| Stroke undo | Present: shared undo response |
| Region clearing | Present |
| Region clear preview and armed highlight | Missing |
| Add car/train route from endpoints | Missing |
| Directions preview and confirmation | Missing |
| Railway lines | Present: shared vector sources and line layers |
| Railway group / technical controls | Missing |
| Station/site symbols and cards | Missing |
| Railway tile-health banner | Missing |
| Airline airports | Present |
| Airfields / helipads / closed category toggles | Missing |
| Airport labels and symbol parity | Partial: native circle pins |
| Airport information card | Present; native hit uses feature coordinates |
| Hiking trail raster overlay | Present |
| Cycling / MTB / slopes themes | Added |
| Trail strength slider | Added; default corrected to web 75% |
| Nearby trail candidate inspection | Missing |
| Trail geometry/details / GPX export | Missing |

## Photos and device features

| Web feature | Flutter comparison |
|---|---|
| Local geotagged photo pins | Present: Swift photo bridge |
| Tapped photo filtering | Corrected: gallery starts from matching pin indices |
| Photo clustering and count pins | Missing |
| Swipe gallery, zoom photo, play video | Present |
| Gallery navigation follows the map | Missing |
| Photo location sync, no image uploads | Present: existing native bridge |
| Background location cadence and precision | Present; physical-device background wake not verified |
| HealthKit workout import | Present; simulator has limited Health data |
| Device name, pending fix count and manual sync | Present |
| Device list status/forget controls | Partial: connection list exists, management incomplete |
| Permission onboarding cards | Missing; native APIs ask when used |

## Data, statistics, settings and administration

| Web feature | Flutter comparison |
|---|---|
| Ground totals / countries / days / streak / dates | Present: shared statistics |
| Country coverage bars | Present |
| Annual new-ground chart | Present |
| Region breakdown inside countries | Added; exact web eight-region preview expansion differs |
| Area/share ordering and geographic grouping | Partial: area/share sorting added; geographic grouping differs |
| File import shared format parsers | Present: server import path |
| Import source choice / include-routes choice / preview report | Partial: Flutter imports immediately with fewer options |
| Multi-file imports and archive selection | Partial |
| Komoot one-time tour-link lookup/import | Missing; web performs client-side fetch, not OAuth |
| Source visibility | Present |
| Source rename / merge | Added: existing shared rename endpoint |
| Source removal with confirmation | Added: existing shared delete endpoint |
| Strava setup, OAuth and manual sync | Present: native authentication bridge |
| Strava schedule, status, activity-route settings, disconnect | Partial |
| Home Assistant probe, entity selection, setup and sync | Present |
| Home Assistant interval/accuracy/status/disconnect | Partial |
| Home place selection | Present |
| Automatic home / marker / show-home toggle | Partial |
| 12h / 24h clock choice | Present; complete formatted-time use still differs |
| Language chooser | Web currently ships English only; Flutter has generated English catalogue but many literal labels |
| What's new frequency and banner | Missing |
| Clear cache | Missing as a settings action |
| Account login / registration / session cookie | Present: native shared cookie bridge |
| Account sign out | Present |
| Account deletion, password confirmation | Added: existing shared authenticated deletion endpoint |
| Export current map snapshot to Photos | Present |
| Export presets, size/resolution, custom dimensions | Missing |
| Export geographic selection/crop/fit | Missing |
| Export colours, borders, surroundings and strength | Missing |
| Export caption/font/size/shadow/layout | Missing |
| Export preview and share composition | Missing |
| Backup list, run and download/share | Present for administrators |
| Backup cron presets, retention, schedule configuration | Missing |
| Administrator account list | Present |
| Administrator create/delete/rename/reset-password | Missing |
| Administrator impersonation / leave | Missing |
| Intro deck / replay intro / finish flow | Missing |
| Swipeable top notification and replacement | Corrected: overlay above sheets, swipe/close/timer; trip/day and workout banners identify the selection |
| Reduced-motion handling | Added for toast, sheet and control lift; not all map animations |
| Offline retry banner | Added at top; complete web recovery state differs |
| Persistent offline recovery | Missing; reads have conditional in-memory cache |
| Portrait glass, compact menu and responsive keyboard bounds | Content-sized panels with height cap; continuous 43px phone corners inside 12px screen margins; hardware-radius match is a visual approximation |
| Landscape columns and responsive panel placement | Partial |
| iOS transitions and segmented controls | Improved: Cupertino controls and transitions; web animation choreography remains different |

## Evidence and limits

Verification for this change: `flutter analyze` passed, 15 Flutter tests passed,
the render API suite passed 97 checks, the full `npm test` suite passed, and the
repeatable iPhone 17 Pro simulator integration flow passed. The simulator also
verifies distinct overlap palette dots, hidden controls, calendar selection,
upward day-banner dismissal and horizontal named-workout dismissal. Screenshots
were inspected for the menu, overlap chooser, day track and metric routes.

Source inventory: `sporra-webserver/index.html` and the UI modules for search,
calendar, activity cards, statistics, sources, personal settings, map layers,
railways, airports, trails, photos, import/Komoot, sync, export, backups,
administration, introduction, notifications and offline recovery. Native
comparison: `sporra-flutter/lib/src`, its Swift bridge and integration tests.

Automated checks cover shared cell hit vectors, blob shaping, visit summaries,
owner isolation, route/track segment rules, visible-country fine LOD requests,
photo time windows, top toast replacement/dismissal, graphs and layer patches.
The iPhone simulator flow covers near-route taps, activity graph/map scrubbing,
region/country/continent native polygon hits and screenshot pixels, yellow day
tracks, immediate visited card content, overlapping activities, menu layout,
edit undo, session restoration and sign-out.

No side-by-side browser screenshot session was available during this audit.
Screenshots of Flutter alone cannot establish visual identity. Real device
background tracking, large photo libraries, third-party connector credentials
and full 3D/export behavior require their own verification. Remaining rows
above are explicit work items, not accepted deviations from the parity target.
