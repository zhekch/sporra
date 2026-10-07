// --- What is drawn before anybody chooses --------------------------------------

/**
 * Which groups are on for someone who has never opened the list.
 *
 * Not "all of them", which is what an absent key used to mean. The overlay draws
 * six kinds of thing over a map that already has a map on it, and three of them
 * are for reading a railway rather than seeing where one is: the line-number
 * shields are the densest labels on the whole map, the kilometre posts are a
 * number every few hundred metres, and the signals are both dense and the only
 * reason the 1.5 MB full-colour sprite atlas is ever fetched. Someone who
 * switches the overlay on wants to see where the tracks are; the rest is there
 * for when they ask.
 */
export const RAIL_GROUP_DEFAULTS = {
  linenumbers: false,
  tracks: true,
  stations: true,
  symbols: false,
  platforms: true,
  milestones: false,
};

/** Whether a group is on, given what has been chosen and what defaults to. */
export const railGroupOn = (chosen, key) => chosen?.[key] ?? RAIL_GROUP_DEFAULTS[key] ?? true;

// --- Technical infrastructure --------------------------------------------------
//
// One switch over the parts of a railway that are not a railway you could travel
// on: the sidings and yard roads a train is only ever shunted along, the line
// that was lifted in 1974, and the "stations" that are a junction, a site or a
// point where two tracks cross. All of it is real and correctly mapped, and all
// of it doubles the amount of ink on the screen around any station of any size.
//
// **The switch is a filter, not a visibility.** These are properties of features
// rather than whole layers — a single track layer draws both the through line and
// the siding beside it — so a group toggle cannot express it.
//
// **And it is one global-state key rather than 253 setFilter calls.** MapLibre
// re-parses a source's tiles when a filter changes, so flipping this layer by
// layer would do that work 253 times over. The filters are written once at
// install in terms of a key of ours, exactly the way their own style is written
// in terms of theirs, and the switch sets the key.

/** Ours, and namespaced so an upstream `state` key can never collide with it. */
export const TECHNICAL_STATE = 'sporraTechnical';

/**
 * Their own four switches for infrastructure that is not running railway.
 *
 * Free configuration rather than filters of our own — the style consults these
 * itself. Their defaults disagree with each other (construction and proposed
 * are on out of the box, abandoned and razed are off), which is a fine answer
 * for a map *of* railways and the wrong one for an overlay on a map of
 * somewhere. All four follow the one switch instead.
 */
export const ORM_STATE_SWITCHES = [
  'showConstructionInfrastructure',
  'showProposedInfrastructure',
  'showAbandonedInfrastructure',
  'showRazedInfrastructure',
];

/**
 * The states their switches do not cover. `disused` is track that is still there
 * and no longer used, which has no switch of theirs; the other four are listed
 * as well so that the filter reads as the whole rule rather than half of it.
 */
const TECHNICAL_LINE_STATES = ['disused', 'construction', 'proposed', 'abandoned', 'razed'];

/**
 * Station features that are operational furniture rather than somewhere to catch
 * a train. `halt` is in the list because it is: their `halt` is `railway=halt`,
 * an unstaffed stopping point, and it is the value that most often turns a
 * junction-dense area into a wall of labels. Move it out of here if the small
 * stops are what you are looking at.
 */
const TECHNICAL_STATION_FEATURES = [
  'service_station', 'yard', 'crossover', 'junction', 'spur_junction', 'site', 'halt',
];

// Which rule each source layer answers to. A track carries `service` and `state`;
// a station carries `feature`. Everything else — platforms, signals, kilometre
// posts — has its own group and is left alone.
export const TRACK_SOURCE_LAYERS = new Set(['railway_line_high', 'standard_railway_line_low']);
export const STATION_SOURCE_LAYERS = new Set([
  'standard_railway_text_stations',
  'standard_railway_text_stations_low',
  'standard_railway_text_stations_med',
  'standard_railway_grouped_stations',
  'standard_railway_grouped_station_areas',
]);

/**
 * The extra filter one source layer's features have to pass, or null.
 *
 * `coalesce` to the empty string rather than testing the property directly:
 * `match` on a missing property evaluates its input to null, and null is not one
 * of the labels *or* the fallback — it is a type error, which in a filter means
 * the layer draws nothing at all.
 */
export function technicalFilter(sourceLayer) {
  const ordinary = TRACK_SOURCE_LAYERS.has(sourceLayer)
    ? ['all',
      // Any `service` value at all — spur, yard, siding, crossover — is a track
      // a service moves over rather than one it runs on.
      ['==', ['coalesce', ['get', 'service'], ''], ''],
      ['match', ['coalesce', ['get', 'state'], ''], TECHNICAL_LINE_STATES, false, true]]
    : STATION_SOURCE_LAYERS.has(sourceLayer)
      ? ['match', ['coalesce', ['get', 'feature'], ''], TECHNICAL_STATION_FEATURES, false, true]
      : null;
  // `to-boolean` around the switch, and it is not decoration. `global-state`
  // evaluates to **null** for a key nobody has set, `any` wants booleans, and a
  // filter that throws does not fail loudly — it draws nothing. Every track and
  // every station in the overlay reads this expression, so one ordering mistake
  // that left the key unset would empty the map of railways with no error worth
  // the name. Coerced, an unset key reads as "off", which is the default anyway.
  return ordinary && ['any', ['to-boolean', ['global-state', TECHNICAL_STATE]], ordinary];
}

