# Codex Go

以工作区和对话为中心的远程 Codex Android 客户端。通过 SSH 连接你的开发环境，在手机上继续已有会话、查看执行进度、回答问题和确认权限。代码与任务执行留在远端电脑上。

本项目处于 `0.1.0` 预览阶段，独立维护，非 OpenAI 官方应用。当前支持 Android；其他平台尚未验证。

## 使用方式

1. 在「连接」中添加 SSH 主机。支持密码、私钥、独立跳板机凭据与 SSH 配置导入。
2. 首次连接时核对并确认主机指纹。共享服务模式默认复用远端 Codex 服务；也可以选择独立服务或指定 Unix socket。
3. 在「工作区」中选择目录，或者在「对话」中浏览这台主机的近期会话。工作区会结合共享项目和完整会话历史自动发现，按最近活动排序。
4. 打开已有对话，或新建对话后发送第一条消息。运行过程中可以停止、插话、排队发送和处理中断后的下一条消息。
5. 在「设置」中切换简体中文 / English，以及系统 / 明亮 / 深色外观。主机凭据保存在系统安全存储中。

远端需要可用的 SSH 服务及支持 app-server 协议的 Codex。首次使用前，应在远端完成 Codex 安装与登录。客户端不会内置账号、API 密钥或远端主机地址。

## 已包含的能力

- 工作区发现、最近活动排序、精确目录归属与共享项目管理。
- 会话搜索、分页、置顶、归档和恢复；运行中与待处理筛选。
- 流式对话、Markdown 与代码块，按回合组织的执行过程、文件改动与 diff。
- 模型、推理强度、权限范围、技能、MCP、目标与上下文操作。
- 草稿与发送队列持久化、断线重连、后台连接保持和主机指纹校验。
- 附件上传、图片 / 视频预览、文件下载和 SSH 端口转发。
- 手机单栏导航，宽屏会话列表与正文并排显示。

## 开发与构建

已验证的工具链为 Flutter `3.47.7`、Dart `3.13.5`、JDK 17。Android SDK 按 Flutter 的标准方式配置，环境中需要能找到 `flutter`。

```sh
flutter pub get
flutter analyze --no-pub
bash tool/build_android.sh
```

APK 输出至 `build/artifacts/`。默认构建用于本地预览，未提供正式签名时使用 Android 调试签名。

公开发布前，需要在 `android/key.properties` 中配置自己的 `storeFile`、`storePassword`、`keyAlias` 和 `keyPassword`，然后运行：

```sh
bash tool/build_android.sh --signed
```

签名配置、签名文件和 `.env` 均被 Git 忽略，不应提交。项目不包含某台电脑的 SDK、依赖缓存或代理路径；可以通过 `PUB_CACHE`、`GRADLE_USER_HOME` 等标准环境变量复用已有工具链缓存。

Android application ID 为 `dev.codexgo.app`，与 Android-SSH-Codex 独立安装、独立存储，不自动迁移旧应用的主机凭据。

## 代码结构

```text
lib/
  app/              应用入口、生命周期和设计系统
  domain/           会话、工作区、草稿与消息状态模型
  infrastructure/   SSH、Codex RPC、安全存储和平台能力
  runtime/          连接、目录、发送队列、会话操作等职责模块
  features/         工作区导航、对话、主机配置与设置
  shared/           通用视觉组件与媒体能力
  l10n/             中英文 ARB 与本地化入口
android/            独立 Android 工程及原生能力
```

导航状态不由服务器事件驱动。运行时模块共享连接代次，异步请求在切换主机后不得写入新连接状态；远端搜索另有请求代次，避免旧查询覆盖新结果。语言与外观通过独立通知更新，不让每条流式消息重新构建整个应用主题。

本地化由 Flutter 根据 ARB 生成，生成目录不提交；修改文案后运行 `flutter gen-l10n`。

## 来源与许可

本项目采用 MIT 许可，完整条款见 [LICENSE](LICENSE)。

SSH 传输、Codex 协议、会话归并、附件与部分对话呈现，以及 Android 后台连接和预览能力，基于 [Android-SSH-Codex](https://github.com/wkj2333666/Android-SSH-Codex) 改编。参考基线为 `41f1f144e2049da78d471199aa3516bc4f333e59`（v0.4.45 发布准备），同时吸收了本地开发版本中已验证的功能修复和对话交互改进。保留原作者版权声明；新项目的独立维护不代表这些实现从零编写。

Codex Go 重新组织了运行时职责、应用导航、工作区入口、连接管理、视觉系统与构建工程。对话组织方式也参考了 dsh-Go 的产品实践；本项目没有依赖 dsh-Go 的运行时服务或构建目录。
