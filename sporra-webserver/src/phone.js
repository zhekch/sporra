// What a phone is spared.
//
// The map was borderline usable on an iPhone 16 in the app, on the 3D basemap,
// and nothing about it was one mistake: the phone was being asked to draw what a
// laptop draws, on a screen with more pixels than most laptops, through a GPU
// that also composites every sheet of frosted glass lying over the map. This
// module is where "a phone" is decided, once, so that every trade made for one
// is made on the same answer — see "On a phone, less of everything" in
// ARCHITECTURE.md.

// Most device pixels per CSS pixel the map is drawn at on a phone.
//
// An iPhone is 3×, and at 3× the 3D basemap is ~3.3 million pixels of terrain,
// lighting and fog a frame. At 2× it is 44% fewer, and on a 460 ppi screen held
// at a phone's distance the difference is text a shade softer at the very edge
// of what an eye resolves. Nothing else here buys as much.
export const PHONE_MAX_DPR = 2;

// The short side of the *screen*, not the window: a phone held sideways is still
// a phone, and a narrow desktop window is not one.
const PHONE_SHORT_SIDE = 560;

let phone = null;

/** Is this a phone — a coarse pointer on a small screen? Decided once. */
export function isPhone() {
  if (phone == null) {
    try {
      const coarse = globalThis.matchMedia?.('(pointer: coarse)').matches ?? false;
      const s = globalThis.screen;
      const short = s ? Math.min(s.width, s.height) : Infinity;
      phone = coarse && short <= PHONE_SHORT_SIDE;
    } catch {
      phone = false;
    }
  }
  return phone;
}

let native = null;

/**
 * The device's real pixel ratio, whatever the map has been told.
 *
 * For the things that show a photograph or write a file: a picture is looked at
 * rather than panned across, and sizing it for 2× on a 3× screen would be a
 * softer photo for no frame saved.
 */
export const nativePixelRatio = () => native ?? (globalThis.devicePixelRatio || 1);

/**
 * Cap `window.devicePixelRatio` on a phone, before either map library exists.
 *
 * Mapbox GL JS v3 takes no `pixelRatio` option — it reads
 * `window.devicePixelRatio` through a getter every time it sizes its canvas —
 * so the one place both libraries can be told the same thing is the property
 * itself. It is [Replaceable] in WebIDL, so a page may redefine it; CSS layout
 * never reads it and is untouched. Called from boot.js, ahead of the import that
 * loads either library.
 *
 * Everything else in the app that reads the ratio sizes a canvas that is drawn
 * *on* the map — icons, the brush ring, the blob sheet — and is right to follow
 * the map. What is not is asked through `nativePixelRatio()`.
 */
export function capDevicePixelRatio() {
  if (!isPhone()) return;
  const real = globalThis.devicePixelRatio || 1;
  if (real <= PHONE_MAX_DPR) return;
  try {
    Object.defineProperty(globalThis, 'devicePixelRatio', {
      configurable: true,
      get: () => PHONE_MAX_DPR,
    });
    native = real;
  } catch {
    // A browser that will not let it be redefined draws at its own ratio, which
    // is what it did before any of this.
  }
}
