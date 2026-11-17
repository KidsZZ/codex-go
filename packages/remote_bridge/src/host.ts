// 独立 Host：只在设备授权后启动本地 Codex 代理，不安装任何 Codex 插件。
import { randomBytes, createHash } from 'node:crypto';
import { mkdir, readFile, writeFile, rename, stat, unlink, open } from 'node:fs/promises';
import { homedir } from 'node:os';
import { Duplex } from 'node:stream';
import type { Socket } from 'node:net';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { createInterface } from 'node:readline/promises';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { x25519 } from '@noble/curves/ed25519';
import QRCode from 'qrcode';
import { WebSocket } from 'ws';
import { NoiseIkSession } from './noise.js';
import { equal, fromBase64Url, key, MAX_FRAME, MAX_MESSAGE, prologue, relayUrl, SecureMessages } from './protocol.js';

const {values} = parseArgs({options: {
  relay: {type: 'string'}, pair: {type: 'boolean'}, socket: {type: 'string'},
  state: {type: 'string'}, revoke: {type: 'string'}, name: {type: 'string'},
}});
const directory = values.state ?? path.join(homedir(), '.local/state/codex-go-host');
await mkdir(directory, {recursive: true, mode: 0o700});
if ((await stat(directory)).mode & 0o077) throw new Error('Host 状态目录必须仅当前用户可访问（权限 0700）。');
// 避免两个进程并发覆盖身份或信任记录；异常退出的锁需要人工确认后清理。
const lockPath = path.join(directory, 'host.lock');
const lock = await open(lockPath, 'wx', 0o600);
await lock.writeFile(String(process.pid));
const statePath = path.join(directory, 'identity.json');
type Identity = {privateKey: string; publicKey: string; trusted: string[]};
let identity: Identity;
async function persist() {
  const temp = path.join(directory, 'identity.pending');
  await writeFile(temp, JSON.stringify(identity), {mode: 0o600});
  await rename(temp, statePath);
}
try {
  try {
    if ((await stat(statePath)).mode & 0o077) throw new Error('身份文件权限必须为 0600。');
    identity = JSON.parse(await readFile(statePath, 'utf8')) as Identity;
    key(identity.privateKey); key(identity.publicKey);
    if (!Array.isArray(identity.trusted) || identity.trusted.length > 32) throw new Error('INVALID_TRUST');
    identity.trusted.forEach(key);
    if (Buffer.from(x25519.getPublicKey(fromBase64Url(identity.privateKey))).toString('base64url') !== identity.publicKey) {
      throw new Error('IDENTITY_MISMATCH');
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
    const privateKey = randomBytes(32);
    identity = {privateKey: privateKey.toString('base64url'), publicKey: Buffer.from(x25519.getPublicKey(privateKey)).toString('base64url'), trusted: []};
    await persist();
  }
  if (values.revoke) {
    identity.trusted = identity.trusted.filter(value => value !== key(values.revoke));
    await persist(); console.log('设备授权已撤销。');
  } else {
    await run();
  }
} finally {
  await lock.close(); await unlink(lockPath);
}

async function run() {
  if (!values.relay) throw new Error('需要 --relay wss://域名/relay。');
  const url = relayUrl(values.relay);
  const token = process.env.RELAY_HOST_TOKEN;
  if (!token || token.length < 32) throw new Error('需要设置 RELAY_HOST_TOKEN。');
  const label = (values.name ?? '我的电脑').replace(/[\x00-\x1f\x7f]/g, '').slice(0, 80);
  let offer: {secret: string; expires: number} | undefined = values.pair
    ? {secret: randomBytes(32).toString('base64url'), expires: Date.now() + 5 * 60_000} : undefined;
  let confirming = false;
  let stopped = false;
  let current: WebSocket | undefined;
  let cancelPrompt: (() => void) | undefined;
  const stop = () => { stopped = true; cancelPrompt?.(); current?.terminate(); };
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
  const fingerprint = (publicKey: string) => createHash('sha256').update(fromBase64Url(publicKey)).digest('hex').slice(0, 24).toUpperCase();
  console.log(`电脑指纹：${fingerprint(identity.publicKey)}`);
  let displayed = false;
  while (!stopped) {
    await new Promise<void>(resolve => {
      const ws = current = new WebSocket(url, {maxPayload: MAX_FRAME, perMessageDeflate: false, handshakeTimeout: 10_000});
      const sessions = new Map<string, Session>();
      let lastPing = Date.now();
      const heartbeat = setInterval(() => { if (Date.now() - lastPing > 60_000) ws.terminate(); }, 20_000);
      ws.on('ping', () => { lastPing = Date.now(); });
      const registration = setTimeout(() => ws.terminate(), 10_000);
      const send = (value: unknown) => {
        if (ws.readyState !== WebSocket.OPEN || ws.bufferedAmount > 8 * 1024 * 1024) throw new Error('RELAY_DISCONNECTED');
        ws.send(JSON.stringify(value));
      };
      const drop = (id: string) => {
        const session = sessions.get(id);
        if (!session) return;
        sessions.delete(id); session.closed = true;
        clearTimeout(session.deadline); clearTimeout(session.lifetime);
        session.abort.abort(); session.local?.terminate(); session.child?.kill(); session.noise.destroy();
        try { send({type: 'close', id}); } catch { /* 断线时只清理本地资源。 */ }
      };
      ws.on('open', () => send({type: 'register', host: identity.publicKey, token}));
      ws.on('error', () => ws.terminate());
      ws.on('close', () => {
        clearInterval(heartbeat); clearTimeout(registration);
        for (const id of sessions.keys()) drop(id);
        resolve();
      });
      ws.on('message', raw => {
        try {
          const frame = JSON.parse(raw.toString());
          if (frame.type === 'registered') {
            clearTimeout(registration);
            console.log('已连接中转，等待手机。');
            if (offer && !displayed) {
              displayed = true;
              const uri = `codex-go://pair#${Buffer.from(JSON.stringify({v: 1, relay: url, host: identity.publicKey, secret: offer.secret, expires: offer.expires, name: label})).toString('base64url')}`;
              void QRCode.toString(uri, {type: 'terminal', small: true}).then(qr => {
                console.log(qr);
                console.log('二维码有效期 5 分钟；仅向自己的手机展示。扫码后请在此确认手机指纹。');
                // 配对入口是用户可见的一次性凭据，不写入日志文件或持久化状态。
                console.log(`也可在手机的配对页面粘贴：\n${uri}`);
              });
            }
            return;
          }
          if (frame.type === 'error') { ws.close(); return; }
          if (frame.type === 'closed') { drop(frame.id); return; }
          if (frame.type === 'open') {
            if (sessions.size >= 8 || sessions.has(frame.id)) { send({type: 'close', id: frame.id}); return; }
            const client = key(frame.client);
            const noise = new NoiseIkSession({role: 'responder', localPrivateKey: identity.privateKey,
              localPublicKey: identity.publicKey, remotePublicKey: client, prologue: prologue(frame.id, identity.publicKey, client)});
            const session: Session = {noise, secure: new SecureMessages(noise), client, closed: false, authorized: false,
              abort: new AbortController(), queuedBytes: 0, queue: Promise.resolve(), deadline: setTimeout(() => drop(frame.id), 90_000),
              lifetime: setTimeout(() => drop(frame.id), 60 * 60_000)};
            sessions.set(frame.id, session); return;
          }
          const session = sessions.get(frame.id);
          if (!session || frame.type !== 'packet' || typeof frame.data !== 'string') throw new Error('INVALID_PACKET');
          const id: string = frame.id;
          session.queuedBytes += frame.data.length;
          if (session.queuedBytes > 6 * 1024 * 1024) { drop(id); return; }
          // 有序处理握手、授权与业务消息；确认期间不允许提前执行 RPC。
          session.queue = session.queue.then(async () => {
            if (session.closed) return;
            const encryptedSend = (value: unknown) => {
              for (const data of session.secure.encode(value)) send({type: 'packet', id, data});
            };
            if (!session.noise.complete) {
              if (session.noise.readHandshake(fromBase64Url(frame.data)).length) throw new Error('INVALID_HANDSHAKE');
              send({type: 'packet', id, data: Buffer.from(session.noise.writeHandshake()).toString('base64url')}); return;
            }
            const message = session.secure.decode(frame.data);
            if (!message) return;
            if (!session.authorized) {
              if (message.kind !== 'auth') throw new Error('AUTH_REQUIRED');
              if (!identity.trusted.includes(session.client)) {
                if (confirming || !offer || Date.now() >= offer.expires || typeof message.secret !== 'string' || !equal(message.secret, offer.secret)) {
                  throw new Error('PAIRING_REJECTED');
                }
                if (!process.stdin.isTTY) throw new Error('配对需要可交互终端确认。');
                confirming = true;
                const activeOffer = offer;
                const terminal = createInterface({input: process.stdin, output: process.stdout});
                cancelPrompt = () => session.abort.abort();
                try {
                  const answer = await terminal.question(`手机指纹：${fingerprint(session.client)}\n请与手机核对，输入 yes 授权：`, {signal: session.abort.signal});
                  if (answer.trim() !== 'yes' || session.closed || offer !== activeOffer || Date.now() >= activeOffer.expires) throw new Error('PAIRING_REJECTED');
                  if (identity.trusted.length >= 32) throw new Error('TRUST_LIMIT');
                  identity.trusted.push(session.client);
                  try { await persist(); } catch (error) { identity.trusted.pop(); throw error; }
                  offer = undefined;
                } finally { terminal.close(); confirming = false; cancelPrompt = undefined; }
              }
              if (session.closed) return;
              // 代理只访问本机控制 socket，不接受手机提供命令、socket 路径或环境变量。
              const child = spawn('codex', ['app-server', 'proxy', ...(values.socket ? ['--sock', values.socket] : [])], {stdio: 'pipe'});
              session.child = child;
              // proxy 承载原始 WebSocket 字节，不是逐行 JSON。使用 Duplex 包装
              // stdio，避免开放本机 TCP 端口，也不自行实现 WebSocket 编解码。
              const stream = Duplex.from({readable: child.stdout, writable: child.stdin});
              const local = session.local = new WebSocket('ws://localhost/', {
                createConnection: () => stream as Socket,
                maxPayload: MAX_MESSAGE, perMessageDeflate: false, handshakeTimeout: 10_000,
              });
              child.stderr.resume();
              child.on('error', () => drop(id)); child.on('exit', () => drop(id));
              child.stdin.on('error', () => drop(id));
              stream.on('error', () => drop(id));
              local.on('error', () => drop(id)); local.on('close', () => drop(id));
              await new Promise<void>((resolve, reject) => {
                local.once('open', resolve);
                local.once('error', reject);
                local.once('close', () => reject(new Error('LOCAL_CODEX_CLOSED')));
              });
              if (session.closed) return;
              local.on('message', raw => {
                try { encryptedSend({kind: 'rpc', message: raw.toString()}); }
                catch { drop(id); }
              });
              session.authorized = true; clearTimeout(session.deadline);
              encryptedSend({kind: 'authorized'}); console.log('已授权手机连接。'); return;
            }
            if (message.kind !== 'rpc' || typeof message.message !== 'string' || /[\r\n]/.test(message.message)) throw new Error('INVALID_RPC');
            JSON.parse(message.message);
            if (!session.local || session.local.readyState !== WebSocket.OPEN || session.local.bufferedAmount > MAX_MESSAGE) throw new Error('SLOW_CODEX');
            session.local.send(message.message);
          }).catch(() => drop(id)).finally(() => { session.queuedBytes -= frame.data.length; });
        } catch { ws.terminate(); }
      });
    });
    if (!stopped) await new Promise(resolve => setTimeout(resolve, 2000));
  }
  process.off('SIGINT', stop); process.off('SIGTERM', stop);
}
type Session = {
  noise: NoiseIkSession; secure: SecureMessages; client: string; authorized: boolean; closed: boolean;
  local?: WebSocket; queuedBytes: number; child?: ChildProcessWithoutNullStreams; abort: AbortController; queue: Promise<void>;
  deadline: ReturnType<typeof setTimeout>; lifetime: ReturnType<typeof setTimeout>;
};
