import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/crypto/vault_file_format.dart';
import '../../core/security/auto_lock.dart';

/// Documento elegido con el selector del sistema. NO es un archivo del
/// dispositivo: se lee por trozos del proveedor (Android: `content://`; iOS:
/// URL con acceso con alcance de seguridad), de modo que no existe ninguna
/// copia en claro en disco.
abstract interface class PickedDocument implements VaultByteSource {
  String get name;

  /// Tamaño en bytes si el proveedor lo informa.
  int? get size;

  /// Extensión sin punto (minúsculas) o `null`.
  String? get extension;

  /// Libera el flujo del sistema (idempotente). Hay que llamarlo siempre.
  Future<void> close();
}

abstract interface class DocumentPicker {
  /// Abre el selector del sistema. `null` si el usuario cancela.
  Future<PickedDocument?> pick();
}

/// Canal nativo propio `vault/picker`:
/// * Android: `ACTION_OPEN_DOCUMENT` + `ContentResolver.openInputStream`.
/// * iOS: `UIDocumentPickerViewController` (`asCopy: false`) +
///   `startAccessingSecurityScopedResource` + `FileHandle`.
/// // iOS: sin probar.
/// Sin logs de nombres ni rutas.
class PlatformDocumentPicker implements DocumentPicker {
  PlatformDocumentPicker({MethodChannel? channel, int chunkBytes = 1 << 20})
    : _channel = channel ?? const MethodChannel('vault/picker'),
      _chunk = chunkBytes;

  final MethodChannel _channel;
  final int _chunk;

  @override
  Future<PickedDocument?> pick() async {
    // El selector del sistema pone la app en segundo plano: sin esto el
    // autobloqueo la cerraría a mitad de la elección.
    final res = await AutoLockSuspension.instance.run(
      () => _channel.invokeMapMethod<String, Object?>('pick'),
    );
    if (res == null) return null;
    final handle = res['handle'];
    final name = res['name'];
    if (handle is! int || name is! String) return null;
    final size = res['size'];
    return _ChannelDocument(
      channel: _channel,
      handle: handle,
      name: name,
      size: size is int && size >= 0 ? size : null,
      chunk: _chunk,
    );
  }
}

class _ChannelDocument implements PickedDocument {
  _ChannelDocument({
    required MethodChannel channel,
    required this.handle,
    required this.name,
    required this.size,
    required int chunk,
  }) : _channel = channel,
       _chunk = chunk;

  final MethodChannel _channel;
  final int handle;
  final int _chunk;
  bool _closed = false;

  @override
  final String name;

  @override
  final int? size;

  @override
  String? get extension {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1).toLowerCase();
  }

  @override
  Future<Uint8List> read(int length) async {
    if (_closed) return Uint8List(0);
    final n = length > _chunk ? _chunk : length;
    final data = await _channel.invokeMethod<Uint8List>('read', {
      'handle': handle,
      'length': n,
    });
    return data ?? Uint8List(0);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel.invokeMethod<void>('close', {'handle': handle});
    } on Object {
      // el sistema liberará el flujo al cerrar la app
    }
  }
}
