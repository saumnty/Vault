import 'package:cryptography/cryptography.dart';

class SessionManager {
  static SecretKey? _masterKey;

  static void setMasterKey(SecretKey key) {
    _masterKey = key;
  }

  static SecretKey? get masterKey => _masterKey;

  static void clearSession() {
    _masterKey = null;
  }
}