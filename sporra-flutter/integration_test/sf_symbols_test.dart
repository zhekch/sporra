import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sporra_flutter/src/appearance.dart';
import 'package:sporra_flutter/src/place_card.dart';
import 'package:sporra_flutter/src/sf_icon.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iOS renders native menu symbols and visit disclosure', (
    tester,
  ) async {
    for (final name in [
      'figure.run',
      'photo',
      'tram.fill',
      'iphone',
      'link',
      'arrow.triangle.2.circlepath',
      'chevron.right',
    ]) {
      final bytes = await SFIcon.channel.invokeMethod<List<int>>('render', {
        'name': name,
        'size': 24.0,
        'scale': 3.0,
      });
      expect(bytes, isNotNull, reason: name);
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes!));
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 72, reason: name);
      expect(frame.image.height, 72, reason: name);
      frame.image.dispose();
      codec.dispose();
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: webTheme(),
        home: Scaffold(
          backgroundColor: const Color(0xff181818),
          body: Center(
            child: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      SFIcon(
                        'figure.run',
                        fallback: CupertinoIcons.sportscourt,
                      ),
                      SFIcon('photo', fallback: CupertinoIcons.photo),
                      SFIcon('tram.fill', fallback: CupertinoIcons.tram_fill),
                      SFIcon('link', fallback: CupertinoIcons.link),
                    ],
                  ),
                  const SizedBox(height: 20),
                  PlaceCard(
                    info: const {
                      'name': 'Bern',
                      'visited': true,
                      'visitDates': ['2026-10-07'],
                      'visitCount': 1,
                    },
                    onClose: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await binding.takeScreenshot('sf-symbols-visits');
    await tester.tap(find.text('1 visit'));
    await tester.pumpAndSettle();
    expect(find.text('07.10.2026'), findsOneWidget);
  });
}
