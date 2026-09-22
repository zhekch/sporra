// Geotagged photographs, one JSON object per line and nothing else.
//
// The same rule as PhotoLibrary.located: a coordinate, a creation date, no
// identifier and no pixels. The migration stamps those points onto the new
// grid. A library the process cannot read is an exit code, not a guess.
import CoreLocation
import Foundation
import Photos

let sem = DispatchSemaphore(value: 0)
var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
if status == .notDetermined {
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { next in
        status = next
        sem.signal()
    }
    sem.wait()
}
guard status == .authorized || status == .limited else {
    fputs("photo library not readable (\(status.rawValue))\n", stderr)
    exit(1)
}

let options = PHFetchOptions()
options.includeHiddenAssets = false
let assets = PHAsset.fetchAssets(with: options)
let limit = 200_000
var written = 0
assets.enumerateObjects { asset, _, stop in
    guard let where_ = asset.location else { return }
    let c = where_.coordinate
    guard CLLocationCoordinate2DIsValid(c), c.latitude != 0 || c.longitude != 0 else { return }
    guard let taken = asset.creationDate else { return }
    let lat = (c.latitude * 1e5).rounded() / 1e5
    let lng = (c.longitude * 1e5).rounded() / 1e5
    let t = Int(taken.timeIntervalSince1970)
    print("{\"lat\":\(lat),\"lng\":\(lng),\"t\":\(t)}")
    written += 1
    if written >= limit { stop.pointee = true }
}
