import 'package:flutter/foundation.dart';

import 'cloud_storage.dart';
import 'google_drive_cloud_storage.dart';

/// Instancia compartida de [CloudStorage] para los servicios que no reciben
/// inyección (visor, modo sin conexión). La UI y las pruebas inyectan la suya.
abstract final class CloudProvider {
  static CloudStorage? _instance;

  static CloudStorage get instance => _instance ??= GoogleDriveCloudStorage();

  @visibleForTesting
  static set override(CloudStorage? value) => _instance = value;
}
