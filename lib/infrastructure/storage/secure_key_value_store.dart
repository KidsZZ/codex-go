import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 主机凭据只经过系统安全存储，界面层不直接读写持久化数据。
abstract interface class SecureKeyValueStore {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String? value});
  Future<void> delete({required String key});
}

SecureKeyValueStore createSecureKeyValueStore() => AndroidSecureKeyValueStore();

final class AndroidSecureKeyValueStore implements SecureKeyValueStore {
  AndroidSecureKeyValueStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read({required String key}) => _storage.read(key: key);
  @override
  Future<void> write({required String key, required String? value}) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}
