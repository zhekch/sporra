import 'dart:async';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

const standardStyle = 'mapbox://styles/mapbox/standard';
const standardSatelliteStyle = 'mapbox://styles/mapbox/standard-satellite';

String? tokenComplaint(String token) {
  final clean = token.trim();
  if (clean.isEmpty) return 'Paste your public Mapbox token.';
  if (clean.startsWith('sk.')) {
    return 'Use a public token starting with pk. Secret tokens cannot be used in the app.';
  }
  if (!clean.startsWith('pk.')) return 'A Mapbox public token starts with pk.';
  return null;
}

bool usesMapbox(String style, String token) =>
    (style == 'mapbox' || style == 'satellite') &&
    tokenComplaint(token) == null;
String effectiveBasemap(String style, String token) =>
    style == 'mapbox' && !usesMapbox(style, token) ? 'dark' : style;

Future<void> checkMapboxToken(String token, {http.Client? client}) async {
  final complaint = tokenComplaint(token);
  if (complaint != null) throw FormatException(complaint);
  final connection = client ?? http.Client();
  try {
    final res = await connection
        .get(
          Uri.https('api.mapbox.com', '/styles/v1/mapbox/standard', {
            'access_token': token.trim(),
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) return;
    if (res.statusCode == 401) {
      throw const FormatException('Mapbox rejected that token.');
    }
    if (res.statusCode == 403) {
      throw const FormatException(
        'That token cannot read styles or is restricted to other URLs.',
      );
    }
    throw FormatException('Mapbox answered ${res.statusCode}.');
  } on http.ClientException {
    throw const FormatException(
      'Could not reach Mapbox. Check the connection.',
    );
  } on TimeoutException {
    throw const FormatException(
      'Mapbox did not answer. Check the connection and try again.',
    );
  } finally {
    if (client == null) connection.close();
  }
}

// Same solar elevation and civil twilight thresholds as web src/sun.js.
String sunPhase(DateTime when, {double? latitude, double? longitude}) {
  final lat = latitude ?? 0;
  final lon = longitude ?? when.timeZoneOffset.inMinutes / 4;
  const rad = math.pi / 180;
  final d = when.millisecondsSinceEpoch / 86400000 + 2440587.5 - 2451545;
  final anomaly = (357.529 + 0.98560028 * d) * rad;
  final ecliptic =
      (280.459 +
          0.98564736 * d +
          1.915 * math.sin(anomaly) +
          0.02 * math.sin(2 * anomaly)) *
      rad;
  final obliquity = (23.439 - 0.00000036 * d) * rad;
  final declination = math.asin(math.sin(obliquity) * math.sin(ecliptic));
  final ascension =
      math.atan2(math.cos(obliquity) * math.sin(ecliptic), math.cos(ecliptic)) /
      rad;
  final angle =
      ((18.697374558 + 24.06570982441908 * d) % 24) * 15 + lon - ascension;
  final hourAngle = angle - 360 * ((angle + 180) / 360).floor();
  final elevation =
      math.asin(
        math.sin(lat * rad) * math.sin(declination) +
            math.cos(lat * rad) *
                math.cos(declination) *
                math.cos(hourAngle * rad),
      ) /
      rad;
  if (elevation >= 6) return 'day';
  if (elevation <= -6) return 'night';
  return hourAngle < 0 ? 'dawn' : 'dusk';
}
