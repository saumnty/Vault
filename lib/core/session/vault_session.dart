import 'package:cryptography/cryptography.dart';

class VaultSession {
  static final VaultSession _instance = VaultSession._internal();
  factory VaultSession() => _instance;
  VaultSession._internal();

  SecretKey? masterKey;
  
  bool get isUnlocked => masterKey != null;
  
  void clear() {
    masterKey = null;
  }
}