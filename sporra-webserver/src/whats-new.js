// Announcement decisions and named-place identities live on the server.
// This module keeps the frequency setting and legacy snapshot storage so an
// older client can still sync preferences without losing its previous baseline.
import { t } from './i18n.js';

export const BANNER_MODES = [
  { key: 'never', label: t('whatsNew.never') },
  { key: 'substantial', label: t('whatsNew.substantial') },
  { key: 'always', label: t('whatsNew.always') },
];

const DEFAULT_MODE = 'substantial';
const MODE_KEY = 'visited-map:whats-new-mode:v1';
const SNAPSHOT_KEY = 'visited-map:whats-new:v1';

/** Is this a mode we know? Used by the prefs adopter, which is fed by the network. */
export const isBannerMode = (key) => BANNER_MODES.some((m) => m.key === key);

/** Which mode is chosen, falling back to the default for anything odd. */
export function bannerMode() {
  let held;
  try {
    held = localStorage.getItem(MODE_KEY);
  } catch {
    held = null;
  }
  return isBannerMode(held) ? held : DEFAULT_MODE;
}

/** Choose one. Returns what is now stored. */
export function setBannerMode(key) {
  const clean = isBannerMode(key) ? key : DEFAULT_MODE;
  try {
    localStorage.setItem(MODE_KEY, clean);
  } catch {
    /* a preference that will not persist is still a preference */
  }
  return clean;
}


// Legacy counters are retained for preference compatibility only.
const FIELDS = ['cells', 'km2', 'countries', 'regions', 'days', 'streakDays', 'workouts'];

/**
 * A snapshot out of somewhere untrusted — this browser's storage, or the
 * account's preferences blob, which is fed by the network.
 *
 * Every field through Number, so an entry written by an older build, truncated
 * by a full disk or edited by hand degrades to zeroes rather than to NaN —
 * which would otherwise propagate into every delta and print "NaN new places"
 * over a perfectly good map.
 *
 * @returns {object|null} null for anything that is not a snapshot at all
 */
export function readSnapshot(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const held = {};
  for (const key of FIELDS) held[key] = Number(raw[key]) || 0;
  return held;
}

/**
 * The two copies of the baseline, as one.
 *
 * Field by field, the larger — see the note at the top. Either side may be
 * missing: a device that has never shown a banner has none of its own, and an
 * account written before this was synced carries none either.
 */
export function mergeSnapshots(a, b) {
  const mine = readSnapshot(a);
  const theirs = readSnapshot(b);
  if (!mine || !theirs) return mine ?? theirs;
  const held = {};
  for (const key of FIELDS) held[key] = Math.max(mine[key], theirs[key]);
  return held;
}

/** Read the stored baseline, or null if there has never been one. */
export function lastSnapshot() {
  try {
    return readSnapshot(JSON.parse(localStorage.getItem(SNAPSHOT_KEY) ?? 'null'));
  } catch {
    return null;
  }
}

/** Write the baseline. Called when something has been said, and never otherwise. */
export function rememberSnapshot(snapshot) {
  if (!snapshot) return;
  try {
    localStorage.setItem(SNAPSHOT_KEY, JSON.stringify(snapshot));
  } catch {
    /* private mode: the banner is a nicety, and it will simply not appear */
  }
}

/** Signing out must not leave the next account measuring against this one's map. */
export function forgetSnapshot() {
  try {
    localStorage.removeItem(SNAPSHOT_KEY);
  } catch {
    /* fine */
  }
}
