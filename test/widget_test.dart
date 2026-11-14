import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/crypto/auth_controller.dart';
import 'package:vault/core/session/vault_session.dart';
import 'package:vault/main.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('VaultApp arranca en la pantalla de PIN (sin bóveda)', (
    tester,
  ) async {
    final controller = AuthController(
      storage: InMemorySecureStore(),
      biometricStore: FakeBiometricKeyStore(),
      kdfParams: fastKdf,
      session: VaultSession.create(),
    );

    await tester.pumpWidget(VaultApp(authController: controller));
    await tester.pumpAndSettle();

    expect(find.text('Crea un nuevo PIN'), findsOneWidget);
    // Teclado propio: 10 dígitos + borrar, y el botón Continuar.
    expect(find.text('5'), findsOneWidget);
    expect(find.text('Continuar'), findsOneWidget);
  });
}
