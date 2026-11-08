// Account and localStorage values use the same mode keys as Flutter.
export function readMapOpacities(value) {
  const out = {};
  for (const mode of ['flat', 'visits', 'oldest', 'type']) {
    const opacity = value?.[mode];
    if (typeof opacity === 'number' && Number.isFinite(opacity)) {
      out[mode] = Math.max(0, Math.min(1, opacity));
    }
  }
  return out;
}

export function mapOpacityFor(values, mode, fallback) {
  return readMapOpacities(values)[mode] ?? fallback;
}
