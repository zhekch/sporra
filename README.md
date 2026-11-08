# Sporra

An interactive world map covered in a hexagonal grid, where you mark the places
you've been. Cells are hexagons in storage but never look like it — they're
blurred and re-cut into soft blobs that flow together, so a map of your life
reads as spilled ink rather than a spreadsheet.

Point it at your location history and it fills itself in.

## The projects

| | |
|---|---|
| **[sporra-webserver/](sporra-webserver/README.md)** | The web app and its Node/SQLite server. This is the product; the other two are ways to carry it. |
| **[sporra-ios/](sporra-ios/README.md)** | A native SwiftUI iPhone and iPad app, with native maps, the same server, and background location recording. |
| **[sporra-flutter/](sporra-flutter/README.md)** | The previous Flutter preview, retained as a migration reference. |
| **[sporra-macos/](sporra-macos/README.md)** | The web app hosted on a Mac, with access to the local photo library. |

They live in one repo because they share the same server. The iOS app uses SwiftUI and native map SDKs; the Mac app hosts the site.
The previous Flutter preview remains available as a migration reference.
The Swift hex-grid maths in `SporraCore` is checked against the JavaScript that
defines it. A change to the shape of the app usually lands
in more than one folder at once.

## Just want to run it?

You only need the first folder. Node 20+ is the one requirement.

```sh
git clone https://github.com/zhekch/sporra.git
cd sporra/sporra-webserver
npm install
npm run dev
```

Open <http://localhost:5173> and register an account — **the first account on an
empty database is always allowed**, and registration closes itself afterwards.
[sporra-webserver/README.md](sporra-webserver/README.md) covers running it
for real, getting your location history in, and the configuration.

The app folders are optional when running the server.

## Working on it rather than using it?

[ARCHITECTURE.md](ARCHITECTURE.md) is the long version — why the grid is what it
is, how the blobs are drawn, the security model, and a number of approaches that
were tried and abandoned for reasons that are not visible from the code alone.
Read it before changing anything non-trivial.

## Licence

[Apache 2.0](LICENSE). Copyright 2026 Yevhen Danyliuk.

The map data comes from other people and keeps its own licences — [NOTICE](NOTICE)
says which, and is the file to carry along if you redistribute this.
