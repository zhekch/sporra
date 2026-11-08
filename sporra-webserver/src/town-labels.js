/** One Mapbox interaction path prevents the background click from selecting
 * a cell after the place-label callback has already opened the town. */
export function townLabel(feature) {
  const { name, class: kind } = feature?.properties ?? {};
  if (!['settlement', 'city', 'town', 'village', 'hamlet'].includes(kind)
      || typeof name !== 'string' || !name.trim() || feature?.geometry?.type !== 'Point') return null;
  const [lng, lat] = feature.geometry.coordinates ?? [];
  return Number.isFinite(lng) && Number.isFinite(lat) ? {name, lng, lat} : null;
}

export function installTownLabelClicks(map, onClick) {
  if (!map.addInteraction) {
    map.on('click', onClick);
    return;
  }
  map.addInteraction('sporra-map-click', {type: 'click', handler: e => { onClick(e); return true; }});
  map.addInteraction('sporra-town-click', {
    type: 'click', target: {featuresetId: 'place-labels', importId: 'basemap'},
    handler: e => {
      const town = townLabel(e.feature);
      if (!town) return false;
      onClick(e, town);
      return true;
    },
  });
}
