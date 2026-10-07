import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/photo_markers.dart';

void main() {
  test('a tap selects the closest badge rather than adjacent groups', () {
    final hits = [
      {
        'properties': {'index': 1},
        'geometry': {
          'coordinates': [7.46, 46.95],
        },
      },
      {
        'properties': {'index': 2},
        'geometry': {
          'coordinates': [7.45, 46.95],
        },
      },
    ];
    expect(nearestPhotoHit(hits, 46.95, 7.4501)['properties']['index'], 2);
  });
  test('photo headers count stills and videos separately', () {
    expect(photoCountTitle([]), '0 photos');
    expect(
      photoCountTitle([
        {'video': false},
      ]),
      '1 photo',
    );
    expect(
      photoCountTitle([
        {'video': true},
      ]),
      '1 video',
    );
    expect(
      photoCountTitle([
        {},
        {},
        {'video': true},
      ]),
      '2 photos · 1 video',
    );
  });
  test(
    'a group opens all assets across pages, deduplicating repeated tile hits',
    () async {
      final calls = <int>[];
      final cluster = {
        'type': 'Feature',
        'properties': {'cluster_id': 42, 'point_count': 503},
      };
      final indices = await photoHitIndices(
        [
          cluster,
          cluster,
          {
            'properties': {'index': 700},
          },
        ],
        (_, limit, offset) async {
          calls.add(offset);
          final count = offset == 0 ? 500 : 3;
          return List.generate(
            count,
            (i) => {
              'properties': {'index': offset + i},
            },
          );
        },
      );
      expect(calls, [0, 500]);
      expect(indices.length, 504);
      expect(indices, containsAll([0, 502, 700]));
    },
  );
  test(
    'failed group reads are surfaced instead of opening a partial gallery',
    () async {
      await expectLater(
        photoHitIndices([
          {
            'properties': {'cluster_id': 42, 'point_count': 3},
          },
        ], (_, _, _) async => []),
        throwsStateError,
      );
    },
  );
}
