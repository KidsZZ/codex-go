# Codex Go

[English](README.en.md) · [参与开发](CONTRIBUTING.md) · [安全说明](SECURITY.md) · [MIT License](LICENSE)

在 Android 手机上连接自己的开发电脑，继续 Codex 对话、查看代码改动、处理权限确认。通过 SSH 使用远端 Codex 的原生 app-server 协议，代码、工具和任务执行留在你的电脑上。

**当前处于早期开发阶段。** 本项目独立维护，非 OpenAI 官方应用，也未获 OpenAI 背书。目前面向 Android ARM64 手机；远端已在 Linux 环境验证，其他平台尚未验证。

<p>
  <img src="docs/images/conversations.png" alt="按最近活动组织的会话首页" width="280">
  <img src="docs/images/conversation-dark.png" alt="深色主题下的对话、执行过程和代码块" width="280">
</p>

截图来自真实界面的示例数据，不含个人主机或真实对话。

## 它能做什么

- **接着工作**：浏览、搜索和继续已有会话，置顶、归档与恢复会话。
- **按项目组织**：结合共享项目和完整会话历史发现工作区，按最近活动排序。
- **读懂执行过程**：流式回复、分钟级消息时间、可展开的动作记录、文件改动与 diff；代码支持高亮、复制和换行。
- **控制下一步**：选择模型、推理强度与权限；停止生成、插话、排队发送，回答 Codex 提问和权限请求。
- **传递上下文**：上传附件，上传图片前可裁剪、画笔标注、撤销或选择原图；支持图片和视频预览、远端文件下载，以及通过 SSH 转发端口查看开发服务。
- **适应手机使用**：保存草稿与发送队列，支持重连和后台连接保持，提供简体中文 / English、明亮 / 深色外观。

## 开始使用

### 1. 准备远端电脑

- 手机能够通过 SSH 访问这台电脑，且你拥有对应账号与凭据。
- 按 [Codex CLI 官方文档](https://developers.openai.com/codex/cli)安装 Codex，并先在远端终端完成登录。
- 当前开发环境使用 **Codex CLI 0.167.1**。这是验证基线，不代表最低兼容版本。

本客户端依赖 app-server 的 Unix socket 和 `proxy` 子命令；默认共享模式还需要 `daemon start`，或已经运行的共享服务。可以在远端先检查：

```sh
codex --version
codex app-server --help
codex app-server proxy --help
codex app-server daemon --help
```

若缺少对应子命令或 `unix://` 监听方式，请先升级到具有这些能力的 Codex 版本。官方协议说明见 [Codex app-server](https://developers.openai.com/codex/app-server)。协议仍在演进，暂不承诺兼容所有新旧版本。

### 2. 安装 Android 客户端

正式发布的安装包放在仓库的 **Releases** 页面，选择 `arm64-v8a-release.apk`。支持 Android 7.0（API 24）及以上。

GitHub Actions 产物中的 `preview.apk` 用于开发验收，使用调试签名；它与正式发布密钥签名的安装包不能相互覆盖更新。需要自行构建时，见下方说明。

### 应用内更新

从 0.1.1 起，正式签名版可在「设置 → 版本与更新」检查并下载安装新版本。默认每天最多自动检查一次，只显示提示；下载和系统安装均需用户主动确认。安装前会验证大小、SHA-256、包名、版本和签名身份。预览签名包不参与正式更新。首次安装本功能需要手动升级；更新依赖 GitHub 网络可达性。

正式版与 Beta 是两个独立 App，分别使用 dev.codexgo.app 与 dev.codexgo.app.beta，数据和更新渠道独立。Beta 只接收公开预发布，正式版只接收公开正式发行；安装会中断客户端连接。首次安装 Beta 需要手动下载 APK，此后可在 App 内升级。

发布前更新 pubspec.yaml 的基础版本和递增构建号（例如 0.1.2+3），提交并推送 main，然后执行 node tool/release.mjs beta。脚本自动生成 beta.N，工作流完成签名、校验和公开预发布。验收后执行 node tool/release.mjs release --beta v0.1.2-beta.1 --publish；不加 --publish 则生成草稿。也可以打开 GitHub Actions → Release → Run workflow，选择 release 并填写 source_beta，勾选 publish 后正式公开。

正式版固定使用指定 Beta 的源码提交重新构建，不能直接覆盖 Beta APK。基础构建号 B 对应 Beta 构建号 B×1000+N，正式版 B×1000+999；更新元数据从实际 APK 提取版本号（包含 ABI 偏移），并记录源码提交。所有版本沿用原发布密钥，不覆盖已有标签。

独立中转部署入口为 tool/deploy_relay.sh，通过 NODE_RUNTIME 指定服务器 Node 路径、CADDY_SITE 指定既有站点配置，参数传 SSH 别名。服务监听本机 8081，保留上一版本；脚本只生成 Caddy 修改，管理员检查后执行服务器上的 enable-route.sh，启用 /codex-go-beta/ 子路径并保留原 dsh 服务。

### 3. 添加连接并开始对话

1. 打开「连接」，填写 SSH 地址、端口和用户名，选择密码或私钥认证。需要时可配置跳板机，或导入 SSH 配置。
2. 首次连接时核对主机指纹，再确认连接。
3. 服务模式保持默认的「共享服务」即可，通常**不需要填写 socket 路径**。
4. 在「工作区」选择目录，或从「对话」打开已有任务；新建对话后发送第一条消息。

| 服务模式 | 适用情况 | 是否需要填写 socket |
| --- | --- | --- |
| 共享服务（默认） | 启动或复用远端 Codex 管理的共享服务 | 不需要，自动获取 |
| 独立服务 | 为 Codex Go 启动单独的 app-server 进程 | 不需要，自动管理 |
| 指定 socket | 连接你自己管理的现有 app-server | 需要填写远端绝对路径 |

三种模式均通过 SSH 访问远端，不需要把 app-server 端口暴露到公网。独立服务指单独的服务进程；它仍使用同一远端用户的 Codex 账号和数据目录，不等同于账号或工作区隔离。

## 扫码中转 Demo

连接页右上角的扫码按钮可配对独立的 Codex Go Host。电脑显示二维码，手机核对电脑指纹后请求配对；电脑终端显示手机指纹，输入 `yes` 才授权。Codex 本身无需安装插件。

`packages/remote_bridge` 同时提供云端 Relay 和电脑 Host，要求 Node.js 22 或更新版本。在云服务器和电脑各准备一份该目录并执行：

```sh
npm ci
npm run build
```

云服务器设置注册令牌后启动 Relay，默认仅监听 127.0.0.1:8080。公网应通过支持 WebSocket 的 HTTPS 反向代理暴露 `/relay`，健康检查为 `/healthz`。令牌至少 32 字符，应随机生成并通过安全方式交给电脑；手机无需这个令牌。

```sh
export RELAY_HOST_TOKEN='<随机注册令牌，云端和电脑保持一致>'
npm run relay
```

电脑先完成 Codex 登录并启动本地服务，然后启动 Host：

```sh
codex app-server daemon start
export RELAY_HOST_TOKEN='<与云端一致的注册令牌>'
npm run host -- --relay wss://你的域名/relay --pair --name '我的电脑'
```

Host 通过 `codex app-server proxy` 接入本地服务；自管 socket 可加 `--socket /绝对路径/codex.sock`。保持终端打开，扫描其中的二维码并确认。配对成功后，后续启动去掉 `--pair` 即可；新增手机时重新带上该参数。二维码有效期 5 分钟，只能授权一台新设备，也可将终端显示的配对内容粘贴到手机。

- **信任边界**：二维码直接携带电脑公钥及一次性秘密；手机固定电脑身份，电脑持久化授权的手机公钥。秘密仅在 Noise IK 加密通道中传递。云端注册令牌只限制 Host 注册，不授予电脑操作权限。中转仍能观察设备标识、时间和流量，并可拒绝服务。
- **协议来源**：参考 dsh-Go 的远程连接分层与配对体验；Node Noise 封装改编自 MIT 的 ds-harness-remote。手机使用 cryptography 的密码实现，按 Noise rev34 驱动固定 IK 发起端；没有复制 dsh-Go 的 AGPL 状态机。此 Demo 使用独立的 `CODEX-GO v1` 协议，不与 DSH Relay 混用。
- **支持范围**：会话列表、文本对话、流式输出、原生操作审批和重新连接。文件上传下载、远端图片/视频和端口预览暂不支持。连接中断不会自动重发不确定是否已执行的 RPC；回到 App 后由现有会话恢复逻辑更新状态。
- **凭据与撤销**：手机私钥使用平台安全存储；Host 默认将身份和信任名单存于 `~/.local/state/codex-go-host`（目录 0700，文件 0600）。删除手机上的连接不等于撤销电脑授权。停止 Host 后，执行 `npm run host -- --revoke '<手机公钥>'`，再启动服务。手机公钥可从本机身份文件的 `trusted` 数组查看；不要公开整个身份文件，它包含电脑私钥。自定义 `--state` 时撤销也需指定同一路径。
- **运行边界**：Host 限制 8 条同时连接、32 台授权设备、4 MiB 单条消息；每小时重建加密连接。首次配对需要可交互终端。异常退出留下 `host.lock` 时，应核对其中 PID 对应进程已停止，再移除该锁，不能并行启动同一身份的多个 Host。
- **验证边界**：这仍是 Demo，尚未经过独立安全审计或公网长期运行验证。关闭终端会停止 Host；手机系统的后台限制仍然适用。

开发时可使用 `ws://127.0.0.1:端口/relay`；其他地址必须使用 WSS。没有手机时，可在仓库根目录运行 `dart run tool/relay_probe.dart`，粘贴配对内容并在电脑确认。该诊断只验证初始化，不读取会话或调用模型；结束时会给出临时诊断身份的撤销命令。

## 从源码构建

工具链版本固定在 [tool/flutter-sdk.json](tool/flutter-sdk.json)：Flutter **3.47.7**（包含 Dart 3.13.5）、JDK **17**。安装 Android SDK、接受 SDK 许可，并确保 `flutter doctor -v` 中 Android 工具链可用。脚本需要 Bash；Windows 开发者可使用合适的 Bash 环境。

进入源码目录后执行：

```sh
flutter pub get --enforce-lockfile
bash tool/check.sh
bash tool/build_android.sh --no-pub
```

默认生成优化过的开发预览包和校验文件：

```text
build/artifacts/codex-go-0.1.1-arm64-v8a-preview.apk
build/artifacts/codex-go-0.1.1-arm64-v8a-preview.apk.sha256
```

`--debug` 生成调试构建；`--signed` 生成正式签名构建。依赖锁文件提交到仓库；工具链和依赖缓存不提交，可通过标准 `PUB_CACHE`、`GRADLE_USER_HOME` 环境变量复用。

应用 ID 为 `dev.codexgo.app`。它与 Android-SSH-Codex 独立安装、独立存储，不自动迁移旧应用凭据。

## 常见问题与限制

- **SSH 已连上，但服务或隧道失败**：先核对远端 Codex 登录状态及上述子命令；客户端会尝试解析非交互 SSH 环境的 PATH。自定义安装可在主机配置中补充环境变量。查看错误阶段时，要区分 SSH、远端服务启动和 socket 代理。
- **没有出现预期工作区**：工作区来自共享项目记录和会话工作目录；它不是扫描磁盘上的每个文件夹。没有任何记录的目录需要手动新建工作区或会话。
- **历史消息没有时间**：只显示服务端实际记录的时间，不用刷新时间补造历史时间。
- **后台连接被系统终止**：Android 的省电策略可能限制后台服务；客户端提供重连，但无法保证任意设备上永不断线。
- **平台支持**：当前发布目标为 Android ARM64；iOS、桌面客户端、其他 CPU 架构与其他远端系统不在已验证范围内。

## 参与开发

请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。Bug 和功能建议可使用仓库的 Issue 模板；涉及凭据或安全漏洞时，请先阅读 [SECURITY.md](SECURITY.md)。

```text
lib/app/             应用入口、生命周期与主题
lib/domain/          会话、工作区、草稿与状态模型
lib/infrastructure/  SSH、Codex RPC、安全存储与平台接口
lib/runtime/         连接、目录、消息队列与会话操作
lib/features/        对话、工作区、连接与设置界面
lib/shared/          通用组件、格式化与媒体能力
lib/l10n/            中英文文案
android/             Android 原生能力
```

## 来源与许可

本项目采用 [MIT License](LICENSE)。

SSH 传输、Codex 协议、会话归并、附件和部分对话呈现，以及 Android 后台连接与预览能力，基于 [Android-SSH-Codex](https://github.com/wkj2333666/Android-SSH-Codex) 改编。参考基线为 `41f1f144e2049da78d471199aa3516bc4f333e59`，并吸收了本地版本已验证的修复；原作者版权与许可保留在 [LICENSE](LICENSE) 和 [资源许可](assets/licenses/android-ssh-codex.txt) 中。

Codex Go 独立组织应用导航、运行时职责、工作区、连接管理、对话体验和构建工程。对话交互参考了 dsh-Go 的产品实践，项目运行与构建不依赖 dsh-Go 的目录或服务。

代码字体使用 JetBrains Mono，遵循 [SIL OFL 1.1](assets/licenses/jetbrains-mono.txt)；语法高亮使用 re_highlight。其他依赖的许可可在应用的开源许可页面查看。

Gradle Wrapper 来自 Gradle 官方发行版本，遵循 Apache License 2.0；完整许可保留在 `android/gradle/wrapper/gradle-wrapper.jar` 的 `META-INF/LICENSE` 中。
