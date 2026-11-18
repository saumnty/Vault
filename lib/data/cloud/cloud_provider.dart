import 'package:flutter/foundation.dart';

import 'cloud_storage.dart';
import 'google_drive_cloud_storage.dart';
import 'slot_guarded_cloud.dart';

/// Instancia compartida de [CloudStorage] para los servicios que no reciben
/// inyección (visor, modo sin conexión). La UI y las pruebas inyectan la suya.
///
/// D67 (fase 8): el Drive real va envuelto en [SlotGuardedCloudStorage]: con
/// la bóveda secundaria abierta toda operación lanza [CloudSlotException].
abstract final class CloudProvider {
  static CloudStorage? _instance;

  static CloudStorage get instance =>
      _instance ??= SlotGuardedCloudStorage(GoogleDriveCloudStorage());

  @visibleForTesting
  static set override(CloudStorage? value) => _instance = value;
}
