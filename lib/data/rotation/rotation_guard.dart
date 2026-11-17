import '../../core/crypto/key_rotation_store.dart';
import '../sync/sync_service.dart' show RotationGuard;

/// [RotationGuard] real: lee (de forma síncrona) el último registro de la
/// rotación que conoce el [RotationKeyStore] compartido. El registro se carga
/// al desbloquear (`AuthController`) y se actualiza en cada cambio de fase.
class StoreRotationGuard implements RotationGuard {
  StoreRotationGuard(this.store);

  final RotationKeyStore store;

  RotationRecord? get _rec => store.record.value;

  @override
  bool get active => _rec != null;

  @override
  bool get freezeMeta => _rec?.freezeMeta ?? false;

  @override
  int get fromGen => _rec?.fromGen ?? 1;

  @override
  int get toGen => _rec?.toGen ?? 1;
}
