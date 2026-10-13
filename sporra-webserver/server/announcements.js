// The server owns both the decision and the baseline. Clients only display
// this answer, so visiting on the phone cannot repeat news on the laptop.
const SUBSTANTIAL_KM2 = 400;
const ALWAYS_GROUND_KM2 = 1;
const NAME_LIMIT = 3;

const names = (items) => {
  const shown = items.slice(0, NAME_LIMIT).map(item => item.name);
  if (items.length > NAME_LIMIT) shown.push(`${items.length - NAME_LIMIT} more`);
  return shown.length < 2 ? shown[0] ?? '' : `${shown.slice(0, -1).join(', ')} and ${shown.at(-1)}`;
};

export function announcementFor(before, now, mode = 'substantial', quiet = false) {
  const silent = { show: false, title: '', detail: '', activities: 0, activityIds: [] };
  if (!before || quiet || mode === 'never') return silent;
  const added = key => {
    const seen = new Set(before[key] ?? []);
    return (now[key] ?? []).filter(item => !seen.has(item.id));
  };
  const countries = added('countries');
  const cities = added('cities');
  const regions = added('regions');
  const seenRoutes = new Set(before.activityIds ?? []);
  const activities = now.activities.filter(activity => !activity.ids.some(id => seenRoutes.has(id)));
  const ground = Math.max(0, now.km2 - (before.km2 ?? 0));
  const lines = [];
  if (countries.length) lines.push(`New ${countries.length === 1 ? 'country' : 'countries'}: ${names(countries)}`);
  if (cities.length) lines.push(`First visit to ${names(cities)}`);
  else if (regions.length) lines.push(`New ${regions.length === 1 ? 'region' : 'regions'}: ${names(regions)}`);
  if (ground >= (mode === 'always' ? ALWAYS_GROUND_KM2 : SUBSTANTIAL_KM2)) lines.push(`${Math.round(ground).toLocaleString('en')} km² of new ground`);
  if (!activities.length && !lines.length) return silent;
  return {
    show: true,
    title: activities.length === 1 ? `New activity: ${activities[0].name || 'Workout'}`
      : activities.length ? `${activities.length} new activities` : 'New ground',
    detail: lines.length ? `${lines.join('. ')}.` : 'Added to your map.',
    activities: activities.length,
    activityIds: activities.map(activity => activity.id),
    countries, cities, regions,
  };
}

export function announcementBaseline(before, now) {
  const union = (a, b) => [...new Set([...(a ?? []), ...b])];
  return {
    countries: union(before?.countries, now.countries.map(item => item.id)),
    cities: union(before?.cities, now.cities.map(item => item.id)),
    regions: union(before?.regions, now.regions.map(item => item.id)),
    activityIds: union(before?.activityIds, now.activities.flatMap(activity => activity.ids)),
    km2: Math.max(before?.km2 ?? 0, now.km2),
  };
}
