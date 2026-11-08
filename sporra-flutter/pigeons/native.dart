import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/native.g.dart',
    swiftOut: 'ios/Runner/Native/Native.g.swift',
  ),
)
@HostApi()
abstract class SporraNative {
  String settings();
  @async
  String configure(String json);
  @async
  String sync();
  @async
  void signOut();
  @async
  String photos();
  @async
  Uint8List thumbnail(int index, int pixels);
  @async
  void playVideo(int index);
  @async
  void saveImage(Uint8List png);
  @async
  String authenticate(String url);
}
