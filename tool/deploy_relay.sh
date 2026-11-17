#!/usr/bin/env bash
# 只更新独立 Beta 中转，保留上一个版本；公网 Caddy 配置单独由管理员确认。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
remote="${1:?用法：NODE_RUNTIME=/服务器/node路径 CADDY_SITE=/配置文件 bash tool/deploy_relay.sh SSH别名}"
node_runtime="${NODE_RUNTIME:?需要服务器 Node 22+ 的绝对路径}"
caddy_site="${CADDY_SITE:?需要现有 Caddy 站点配置路径}"
[[ "$remote" =~ ^[A-Za-z0-9_.@-]+$ && "$node_runtime" =~ ^/[A-Za-z0-9_./-]+$ && "$caddy_site" =~ ^/[A-Za-z0-9_./-]+$ ]] || exit 64
git diff --quiet HEAD -- packages/remote_bridge tool/deploy_relay.sh || { echo '请先提交中转代码。' >&2; exit 65; }
revision=$(git rev-parse HEAD)
npm ci --prefix packages/remote_bridge --ignore-scripts
npm run build --prefix packages/remote_bridge
archive=$(mktemp /tmp/codex-go-relay-XXXXXX.tar.gz)
trap 'rm -f "$archive"' EXIT
tar -czf "$archive" -C packages/remote_bridge dist package.json package-lock.json
ssh "$remote" "mkdir -p apps/codex-go-relay-beta/releases/$revision"
scp "$archive" "$remote:apps/codex-go-relay-beta/releases/$revision/bundle.tar.gz"
ssh "$remote" bash -s -- "$revision" "$node_runtime" "$caddy_site" <<'REMOTE'
set -euo pipefail
revision="$1"; node="$2"; caddy_site="$3"
root="$HOME/apps/codex-go-relay-beta"
release="$root/releases/$revision"
export PATH="${node%/node}:$PATH"
[[ "$($node -p 'Number(process.versions.node.split(".")[0])')" -ge 22 ]]
tar -xzf "$release/bundle.tar.gz" -C "$release"
cd "$release"
npm ci --omit=dev --ignore-scripts
umask 077
mkdir -p "$HOME/.config/codex-go-relay-beta" "$HOME/.config/systemd/user"
env_file="$HOME/.config/codex-go-relay-beta/env"
if [[ ! -f "$env_file" ]]; then
  "$node" -e 'const fs=require("fs"),c=require("crypto");fs.writeFileSync(process.argv[1],`RELAY_HOST_TOKEN=${c.randomBytes(32).toString("hex")}\nPORT=8081\nBIND=127.0.0.1\n`,{mode:0o600,flag:"wx"});' "$env_file"
fi
cat > "$HOME/.config/systemd/user/codex-go-relay-beta.service" <<UNIT
[Unit]
Description=Codex Go Beta Relay
After=network-online.target
[Service]
WorkingDirectory=$root/current
EnvironmentFile=$env_file
ExecStart=$node dist/relay.js
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
UMask=0077
[Install]
WantedBy=default.target
UNIT
previous=$(readlink "$root/current" || true)
ln -s "releases/$revision" "$root/current.next.$$"
mv -Tf "$root/current.next.$$" "$root/current"
if [[ -n "$previous" && "$previous" != "releases/$revision" ]]; then ln -sfn "$previous" "$root/previous"; fi
systemctl --user daemon-reload
systemctl --user enable codex-go-relay-beta.service
systemctl --user restart codex-go-relay-beta.service
if ! curl --retry 8 --retry-delay 1 --retry-connrefused --max-time 15 -fsS http://127.0.0.1:8081/healthz; then
  if [[ -n "$previous" ]]; then ln -sfn "$previous" "$root/current"; systemctl --user restart codex-go-relay-beta.service; fi
  echo '健康检查失败，已尝试恢复原版本。' >&2; exit 1
fi
# 生成可审阅的 Caddy 修改，部署账号不绕过管理员的文件权限。
cp "$caddy_site" "$root/caddy.original"
"$node" --input-type=module - "$root" <<'NODE'
import fs from 'node:fs';
const root=process.argv[2];const s=fs.readFileSync(`${root}/caddy.original`,'utf8');
if(s.includes('/codex-go-beta/*')) {fs.writeFileSync(`${root}/caddy.next`,s);}
else {
  const matches=s.match(/^[ \t]*reverse_proxy 127\.0\.0\.1:8080[ \t]*$/gm);
  if(matches?.length!==1)throw Error('站点结构不符合预期，请人工核对，未修改在线配置。');
  fs.writeFileSync(`${root}/caddy.next`,s.replace(matches[0],`\thandle_path /codex-go-beta/* {\n\t\treverse_proxy 127.0.0.1:8081\n\t}\n\thandle {\n\t\treverse_proxy 127.0.0.1:8080\n\t}`));
}
NODE
printf '%s\n' "$caddy_site" > "$root/caddy.target"
cat > "$root/enable-route.sh" <<'ENABLE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$EUID" == 0 ]] || { echo '请用 sudo 执行此脚本。' >&2; exit 1; }
root=$(cd "$(dirname "$0")" && pwd)
target=$(cat "$root/caddy.target")
if cmp -s "$root/caddy.next" "$target"; then echo '路由已经配置。'; exit 0; fi
cmp -s "$root/caddy.original" "$target" || { echo 'Caddy 已被其他操作修改，请重新审阅部署配置。' >&2; exit 1; }
backup="$target.before-codex-go-beta-$(date +%Y%m%d%H%M%S)"
cp -p "$target" "$backup"
install -m 644 "$root/caddy.next" "$target"
if ! caddy validate --config /etc/caddy/Caddyfile || ! systemctl reload caddy; then
  install -m 644 "$backup" "$target"
  systemctl reload caddy
  echo '配置失败，已恢复原站点。' >&2; exit 1
fi
echo 'Codex Go Beta 路由已启用，原 dsh 路由保留。'
ENABLE
chmod 700 "$root/enable-route.sh"
systemctl --user show codex-go-relay-beta.service -p ActiveState -p SubState
printf '管理员公网配置入口：sudo bash %s/enable-route.sh\n' "$root"
REMOTE
