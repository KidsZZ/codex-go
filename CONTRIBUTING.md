# 参与开发 / Contributing

感谢你帮助完善 Codex Go。欢迎使用中文或英文提交 Issue 和 Pull Request。项目仍处于预览阶段，较大的功能或交互调整建议先通过 Issue 讨论使用场景。

## 开发环境

按 README 安装 Flutter、JDK 和 Android SDK；精确 Flutter 版本与源码 revision 记录在 `tool/flutter-sdk.json`，CI 使用相同版本。

```sh
flutter pub get --enforce-lockfile
bash tool/check.sh
bash tool/build_android.sh --no-pub
```

上述检查涵盖格式、静态分析和 Android 编译，不代替真机连接验证。项目目前没有自动端到端测试；请在 PR 中说明实际验证范围，不把编译成功等同于完整功能验证。

## 修改约定

- 界面放在 `features/`，可复用状态规则放在 `domain/`，协议和平台能力放在 `infrastructure/`，跨功能协调放在 `runtime/`。
- 面向用户的文字同时维护 `lib/l10n/app_zh.arb` 和 `app_en.arb`；执行 `flutter gen-l10n`，不提交生成目录。
- 更新依赖时一并更新 `pubspec.lock`。升级工具链时同步检查 SDK 配置、版本约束、CI 与 README。
- 连接和文件操作要保留主机指纹校验、权限确认、取消能力及切换主机后的异步结果隔离。
- 协议或数据结构调整应同步更新所有调用方，避免长期保留两套相同功能。
- 使用清楚的命名和注释解释非直观逻辑；不把个人 SDK 路径、代理配置或调试账号写入代码。
- 引入第三方实现、字体或其他资源时保留其版权和许可说明。

## 提交 PR 前

说明改动解决的问题、使用方式变化，以及运行过的检查。提交消息尽量说明为什么修改、修改了什么及验证结果。

UI 改动请提供明暗主题截图，并检查窄屏、大字号、键盘弹出及长对话。SSH、协议、上传下载或消息队列改动请说明使用的远端 Codex 版本、验证步骤，以及是否做过真实连接验证。

不要提交 `.env`、SSH 私钥、签名密钥、`android/key.properties`、个人主机信息、真实对话、诊断导出或构建产物。Issue 日志和截图也需要去除敏感信息。

## English

Issues and pull requests are welcome in English or Chinese. Discuss substantial feature or interaction changes before implementing them.

Use the toolchain pinned in `tool/flutter-sdk.json`, run the commands above, and describe the problem, resulting behavior, and checks performed. Update both localization files and the dependency lockfile when applicable. Keep UI, domain rules, infrastructure, and runtime coordination in their respective layers.

For UI changes, include screenshots and check light/dark themes, narrow screens, large text, the keyboard, and long conversations. For SSH or protocol changes, identify the Codex version and distinguish real connection checks from compilation or mocked previews. There is currently no automated end-to-end suite.

Never commit credentials, signing material, machine-specific paths, private conversations, or build output. Preserve third-party notices. See `SECURITY.md` for sensitive reports.
