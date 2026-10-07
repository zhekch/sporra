import 'dart:async';
import 'dart:convert';
import 'dart:io';

const mapPreferenceSaveDelay = Duration(milliseconds: 500);
const mapStyles = {'dark', 'terrain', 'voyager', 'satellite', 'mapbox'};

// Camera orientation belongs to this device, not to every account client.
class MapPreferences {
  String style = 'dark';
  double tilt = 0, bearing = 0;
  File? _file;
  String? _scope;
  Timer? _timer;
  Future<void> _writes = Future.value();

  Future<void> restore(File file, String scope) async {
    await flush();
    _file = file;
    _scope = scope;
    style = 'dark';
    tilt = bearing = 0;
    try {
      final data = jsonDecode(await file.readAsString()) as Map;
      if (data['scope'] != scope) return;
      if (mapStyles.contains(data['style'])) style = data['style'] as String;
      final pitch = data['tilt'], heading = data['bearing'];
      if (pitch is num && pitch.isFinite) tilt = pitch.toDouble().clamp(0, 85);
      if (heading is num && heading.isFinite) {
        bearing = heading.toDouble() % 360;
      }
    } catch (_) {
      // Missing or damaged view preferences must not delay opening the map.
    }
  }

  void save() {
    _timer?.cancel();
    if (_file == null) return;
    _timer = Timer(mapPreferenceSaveDelay, () => unawaited(flush()));
  }

  Future<void> flush() {
    _timer?.cancel();
    final file = _file;
    if (file == null) return _writes;
    final data = jsonEncode({
      'scope': _scope,
      'style': style,
      'tilt': tilt,
      'bearing': bearing,
    });
    return _writes = _writes.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(data, flush: true);
        await temporary.rename(file.path);
      } catch (_) {}
    });
  }
}
