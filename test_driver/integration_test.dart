// Driver para ejecutar integration_test en modo profile/release:
//   flutter drive --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/aes_native_test.dart -d emulator-5554
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
