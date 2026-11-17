# Codex Go

[简体中文](README.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT License](LICENSE)

Continue work on your own development machine from an Android phone. Codex Go connects over SSH using Codex's native app-server protocol, so your code, tools, and task execution stay on the remote machine.

**This project is in early development.** This is an independently maintained project, not an official OpenAI application and not endorsed by OpenAI. The current target is Android ARM64; remote connections have been verified on Linux.

<p>
  <img src="docs/images/conversations.png" alt="Conversations ordered by recent activity" width="280">
  <img src="docs/images/conversation-dark.png" alt="Conversation, work log, and code block in dark mode" width="280">
</p>

Screenshots use sample data rendered by the real application. The app supports English and Simplified Chinese.

## Features

- Resume, search, pin, archive, and restore conversations.
- Discover workspaces from shared projects and conversation history, ordered by recent activity.
- Read streaming replies, message timestamps, collapsible work logs, file changes, and diffs. Code blocks support highlighting, copying, and wrapping.
- Choose models, reasoning effort, and permissions; interrupt, steer, or queue messages; answer questions and approval requests.
- Upload attachments; crop and draw on images before upload, undo edits, or keep the original. Preview images and videos, download files, and forward development ports over SSH.
- Keep drafts and an outgoing queue, reconnect after interruptions, and switch between light and dark themes.

## Get started

1. Make your development machine reachable over SSH. Install Codex using the [official CLI documentation](https://developers.openai.com/codex/cli), and sign in on that machine first.
2. Check protocol capabilities. The current development baseline is **Codex CLI 0.167.1**, not a claimed minimum version:

   ```sh
   codex --version
   codex app-server --help
   codex app-server proxy --help
   codex app-server daemon --help
   ```

   The client needs Unix socket transport and `app-server proxy`. Shared mode also needs `daemon start` or an existing shared service. If these capabilities are absent, use a Codex version that provides them. See the [app-server documentation](https://developers.openai.com/codex/app-server). Compatibility with every past or future protocol version is not guaranteed.
3. Install the `arm64-v8a-release.apk` from this repository's Releases page. Android 7.0 / API 24 or later is required.
4. Add an SSH host in **Connections**, using a password or private key. Jump hosts and SSH configuration import are available. Verify the fingerprint before accepting the first connection.
5. Keep **Shared service**, the default, unless you have a specific reason to change it. Open a workspace or an existing conversation and continue working.

| Service mode | Purpose | Socket configuration |
| --- | --- | --- |
| Shared, default | Start or reuse Codex's managed service | Automatic |
| Independent | Start a separate app-server process for Codex Go | Automatic |
| Custom socket | Connect to an app-server you manage | Remote absolute path required |

You normally do not need to enter a socket path or expose an app-server port publicly. All modes use SSH. An independent process still uses the remote user's Codex identity and data; it does not provide account or workspace isolation.

## In-app updates

Starting with 0.1.1, signed release builds can check for updates under Settings → Version & updates. Automatic checks run at most once per day without pop-ups or automatic downloads. Users confirm downloading and system installation. Packages are checked for size, SHA-256, application ID, version and signing identity; preview builds do not receive stable updates. Install the first updater-enabled release manually. GitHub connectivity is required.

Stable and Beta are separate apps (dev.codexgo.app and dev.codexgo.app.beta), with separate data and update channels. Beta accepts public prereleases; stable accepts public stable releases. Install Beta manually once, then use its in-app updater. Installation interrupts connections.

Set the next stable version and increasing base build in pubspec.yaml (for example 0.1.2+3), commit and push main, then run node tool/release.mjs beta. After acceptance, run node tool/release.mjs release --beta v0.1.2-beta.1 --publish; omit --publish for a draft. Users can also run Actions → Release with channel=release, source_beta set to the accepted tag, and publish enabled.

Stable builds use the exact source commit of the accepted Beta. Base build B maps to B*1000+N for Beta and B*1000+999 for stable. Metadata uses the actual APK version code, including its ABI offset. Retain the signing key and never replace existing tags.

Use tool/deploy_relay.sh with NODE_RUNTIME, CADDY_SITE and an SSH alias to deploy the isolated Beta relay on localhost:8081. It retains the previous release and prepares an administrator-reviewed Caddy route under /codex-go-beta/, preserving the existing dsh service.

## QR relay demo

Use the QR button on the Connections page to pair an independent Codex Go Host. Scan the computer's code, verify its fingerprint, then compare the phone fingerprint in the computer terminal and enter `yes`. No Codex plugin is required.

`packages/remote_bridge` contains both the cloud Relay and computer Host. On each machine, use Node.js 22 or newer and run these commands from that directory:

```sh
npm ci
npm run build
```

On the server, set a randomly generated registration token of at least 32 characters and run the Relay. It listens on 127.0.0.1:8080 by default. Expose `/relay` through an HTTPS reverse proxy that supports WebSocket upgrades; `/healthz` is the health endpoint. Transfer the token securely to the computer. The phone does not need it.

```sh
export RELAY_HOST_TOKEN='<random registration token shared with the computer>'
npm run relay
```

On the computer, sign in to Codex, start its local service, then run the Host:

```sh
codex app-server daemon start
export RELAY_HOST_TOKEN='<same registration token>'
npm run host -- --relay wss://your-domain/relay --pair --name 'My computer'
```

The Host uses `codex app-server proxy`; add `--socket /absolute/path/codex.sock` for a custom socket. Keep the terminal open, scan the QR code, and approve the phone. Omit `--pair` on subsequent starts; include it to authorize another phone. Codes expire after five minutes and authorize one new device. Pasting the displayed pairing text into the app is also supported.

- **Trust:** the QR carries the computer public key and a one-time secret directly. The phone pins that key; the Host stores approved phone public keys. The secret travels only inside Noise IK encryption. Cloud registration tokens control Host registration, not computer access. The relay can still observe identifiers, timing and traffic volume, or deny service.
- **References:** connection layering and pairing UX reference dsh-Go. The Node Noise wrapper derives from MIT-licensed ds-harness-remote. The phone drives a fixed Noise rev34 IK initiator using cryptography primitives; it does not copy dsh-Go's AGPL state machine. This demo uses its own `CODEX-GO v1` protocol, not the DSH Relay wire protocol.
- **Scope:** session lists, text chat, streaming, native approvals and reconnection. File transfers, remote image/video loading and port previews are not supported. Uncertain RPCs are not automatically replayed; the existing session recovery flow refreshes state after reconnection.
- **Credentials and revocation:** phone keys use platform secure storage. The Host stores identity and trust under `~/.local/state/codex-go-host` (directory 0700, file 0600). Removing a phone-side connection does not revoke access. Stop the Host, run `npm run host -- --revoke '<phone-public-key>'`, then restart it. Phone keys appear in the local identity file's `trusted` array; never publish that file because it also contains the computer private key. Include the same `--state` when using a custom location.
- **Limits:** eight concurrent links, 32 trusted devices, 4 MiB messages, and a fresh encrypted connection every hour. Pairing requires an interactive terminal. If a crash leaves `host.lock`, verify the recorded process has stopped before removing the lock; never run concurrent Hosts against the same identity.
- **Validation:** this is a demo, without an independent security audit or long-running public-network validation. Closing the terminal stops the Host. Phone background restrictions still apply.

Local development permits `ws://127.0.0.1:port/relay`; all other addresses require WSS. Without a phone, run `dart run tool/relay_probe.dart` from the repository root, paste the pairing text, and approve it on the computer. The probe only initializes Codex, without reading conversations or calling a model, and prints a revocation command for its temporary identity.

## Build from source

[tool/flutter-sdk.json](tool/flutter-sdk.json) pins Flutter **3.47.7** and its source revision. It includes Dart 3.13.5; use **JDK 17**, a configured Android SDK, and accepted Android SDK licenses. Check the Android toolchain with `flutter doctor -v`. The helper scripts require Bash.

From the project directory:

```sh
flutter pub get --enforce-lockfile
bash tool/check.sh
bash tool/build_android.sh --no-pub
```

The default output is an optimized development preview signed with a debug key:

```text
build/artifacts/codex-go-0.1.1-arm64-v8a-preview.apk
build/artifacts/codex-go-0.1.1-arm64-v8a-preview.apk.sha256
```

Use `--debug` for a debug build or `--signed` for a release signed with your own key. The dependency lockfile is committed. SDKs and caches are not; standard `PUB_CACHE` and `GRADLE_USER_HOME` variables can reuse existing caches.

The Android application ID is `dev.codexgo.app`. It installs separately from Android-SSH-Codex and does not migrate that app's saved credentials.

## Limitations and troubleshooting

- If SSH connects but the app-server or tunnel fails, check Codex authentication and the commands above. The client resolves Codex outside an interactive shell; custom installations can supply environment variables in host settings. Distinguish SSH failures from service startup and socket proxy failures.
- Workspace discovery uses shared project records and conversation working directories. It does not enumerate every folder on disk. Create a workspace or conversation for a directory with no existing records.
- Historical message timestamps appear only when the server recorded them; refresh times are never substituted.
- Android battery policies can terminate background connections. Reconnection is supported, but uninterrupted operation on every device is not guaranteed.
- iOS, desktop clients, other CPU architectures, and other remote operating systems are outside the verified scope.

## Contributing and attribution

See [CONTRIBUTING.md](CONTRIBUTING.md) for development conventions and validation. Use the Issue templates for bugs and feature requests, and [SECURITY.md](SECURITY.md) for sensitive reports.

The project uses the [MIT License](LICENSE). SSH transport, Codex protocol handling, conversation merging, attachments, parts of conversation presentation, and Android background/preview support were adapted from [Android-SSH-Codex](https://github.com/wkj2333666/Android-SSH-Codex), based on revision `41f1f144e2049da78d471199aa3516bc4f333e59` and verified local improvements. Original copyright and license notices are retained in [LICENSE](LICENSE) and [the bundled notice](assets/licenses/android-ssh-codex.txt).

Codex Go independently organizes navigation, runtime responsibilities, workspaces, host management, conversation interaction, and builds. Its conversation interaction also draws on dsh-Go's product design; it has no runtime or build dependency on dsh-Go's directories or services.

JetBrains Mono is distributed under [SIL OFL 1.1](assets/licenses/jetbrains-mono.txt). Syntax highlighting uses re_highlight. Dependency notices are available through the app's open-source licenses page.

The Gradle Wrapper comes from the official Gradle distribution under Apache License 2.0. Its full license is retained in `META-INF/LICENSE` inside `android/gradle/wrapper/gradle-wrapper.jar`.
