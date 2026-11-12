// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
abstract interface class RpcTransport {
  Stream<String> get messages;

  void send(String message);

  Future<void> close();
}
