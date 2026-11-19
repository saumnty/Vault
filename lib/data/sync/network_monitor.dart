import 'package:connectivity_plus/connectivity_plus.dart';

/// Tipo de red actual, simplificado.
enum NetworkKind {
  none,
  wifi,
  mobile;

  bool get isOnline => this != none;
}

/// Estado de la red (inyectable; en pruebas un fake).
abstract interface class NetworkMonitor {
  Future<NetworkKind> current();
  Stream<NetworkKind> get changes;
}

/// Traduce la lista de `connectivity_plus` 7.x a [NetworkKind]: Wi-Fi o
/// Ethernet = sin costo (wifi); móvil = datos; VPN/otros se miran por
/// transporte subyacente (si solo hay VPN se trata como wifi).
NetworkKind networkKindFrom(List<ConnectivityResult> results) {
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return NetworkKind.wifi;
  }
  if (results.contains(ConnectivityResult.mobile)) return NetworkKind.mobile;
  if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
    return NetworkKind.none;
  }
  // vpn / bluetooth / other: sin información de costo; se asume no medido.
  return NetworkKind.wifi;
}

class ConnectivityPlusMonitor implements NetworkMonitor {
  ConnectivityPlusMonitor([Connectivity? connectivity])
    : _c = connectivity ?? Connectivity();

  final Connectivity _c;

  @override
  Future<NetworkKind> current() async =>
      networkKindFrom(await _c.checkConnectivity());

  @override
  Stream<NetworkKind> get changes =>
      _c.onConnectivityChanged.map(networkKindFrom).distinct();
}
