import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/state.dart';

void main() {
  test('a trip or day shows only photographs in its full calendar window', () {
    final app = AppState();
    final photos = [
      {'index': 0, 'time': 99},
      {'index': 1, 'time': 100},
      {'index': 2, 'time': 199},
      {'index': 3, 'time': 200},
    ];
    app.track = {'from': 100, 'to': 200};
    expect(app.photosInTrack(photos).map((p) => p['index']), [1, 2]);
    app.track = null;
    expect(app.photosInTrack(photos), photos);
    app.dispose();
  });
}
