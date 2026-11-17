#!/usr/bin/env bash
# 在开发电脑部署独立 Beta Host；令牌通过 SSH 写入私有文件，配对仅在交互终端显示。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
remote="${1:?用法：bash tool/deploy_host.sh SSH别名 wss://域名/codex-go-beta/relay}"
relay="${2:?缺少 WSS 中转地址}"
[[ "$remote" =~ ^[A-Za-z0-9_.@-]+$ && "$relay" =~ ^wss://[A-Za-z0-9.:-]+/([A-Za-z0-9_-]+/)*relay$ ]] || exit 64
node=$(command -v node)
codex=$(command -v codex)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
systemctl --user show-environment >/dev/null
git diff --quiet HEAD -- packages/remote_bridge tool/deploy_host.sh || { echo '请先提交 Host 代码。' >&2; exit 65; }
revision=$(git rev-parse HEAD)
root="$HOME/apps/codex-go-host-beta"
release="$root/releases/$revision"
umask 077
mkdir -p "$release" "$HOME/.config/codex-go-host-beta" "$HOME/.config/systemd/user" "$HOME/.local/bin"
npm ci --prefix packages/remote_bridge --ignore-scripts
npm run build --prefix packages/remote_bridge
cp -R packages/remote_bridge/dist "$release/"
cp packages/remote_bridge/package{,-lock}.json "$release/"
npm ci --prefix "$release" --omit=dev --ignore-scripts
# 固定读取路径，不打印或把服务器其他环境变量带入本机服务。
ssh "$remote" 'cat ~/.config/codex-go-relay-beta/env' | "$node" --input-type=module -e '
import fs from "node:fs";
let s=""; for await (const c of process.stdin) s+=c;
const token=/^RELAY_HOST_TOKEN=([a-f0-9]{64})$/m.exec(s)?.[1];
if(!token)throw Error("中转令牌格式无效");
fs.writeFileSync(process.argv[1],`RELAY_HOST_TOKEN=${token}\n`,{mode:0o600});
' "$HOME/.config/codex-go-host-beta/env"
previous=$(readlink "$root/current" || true)
ln -s "releases/$revision" "$root/current.next.$$"
mv -Tf "$root/current.next.$$" "$root/current"
if [[ -n "$previous" && "$previous" != "releases/$revision" ]]; then ln -sfn "$previous" "$root/previous"; fi
cat > "$HOME/.config/systemd/user/codex-go-host-beta.service" <<UNIT
[Unit]
Description=Codex Go Beta Host
After=network-online.target
[Service]
WorkingDirectory=$root/current
EnvironmentFile=$HOME/.config/codex-go-host-beta/env
Environment=PATH=${codex%/codex}:${node%/node}:/usr/local/bin:/usr/bin:/bin
ExecStart=$node dist/host.js --relay $relay --state $HOME/.local/state/codex-go-host-beta --name Codex-Go-Beta
Restart=on-failure
RestartSec=5
UMask=0077
[Install]
WantedBy=default.target
UNIT
# 配对助手复用同一身份；退出交互配对后恢复后台服务。
cat > "$HOME/.local/bin/codex-go-beta-pair" <<PAIR
#!/usr/bin/env bash
set -euo pipefail
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-unix:path=\$XDG_RUNTIME_DIR/bus}"
export PATH="${codex%/codex}:${node%/node}:\$PATH"
systemctl --user stop codex-go-host-beta.service
trap 'systemctl --user start codex-go-host-beta.service' EXIT
trap ':' INT TERM
set -a
source "$HOME/.config/codex-go-host-beta/env"
set +a
"$node" "$root/current/dist/host.js" --relay "$relay" --state "$HOME/.local/state/codex-go-host-beta" --name Codex-Go-Beta --pair
PAIR
chmod 700 "$HOME/.local/bin/codex-go-beta-pair"
bash -n "$HOME/.local/bin/codex-go-beta-pair"
systemctl --user daemon-reload
systemctl --user enable --now codex-go-host-beta.service
systemctl --user restart codex-go-host-beta.service
systemctl --user show codex-go-host-beta.service -p ActiveState -p SubState
printf '配对入口：%s/.local/bin/codex-go-beta-pair\n' "$HOME"
