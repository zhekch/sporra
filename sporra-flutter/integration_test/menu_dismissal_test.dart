import 'package:integration_test/integration_test.dart';

import '../test/closing_blur_test.dart' as menu_tests;

// Run the same surface and gesture regressions through the iOS renderer too.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  menu_tests.main();
}
