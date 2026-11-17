// 无内容解密能力的中转服务。注册令牌只限制资源使用，不授予电脑操作权限。
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { WebSocket, WebSocketServer } from 'ws';
import { equal, key, MAX_FRAME } from './protocol.js';

const token = process.env.RELAY_HOST_TOKEN;
if (!token || token.length < 32) throw new Error('请设置至少 32 字符的 RELAY_HOST_TOKEN。');
const server = http.createServer((req, res) => {
  res.writeHead(req.url === '/healthz' ? 200 : 404, {'Content-Type': 'text/plain'});
  res.end(req.url === '/healthz' ? 'ok\n' : 'not found\n');
});
const wss = new WebSocketServer({noServer: true, maxPayload: MAX_FRAME, perMessageDeflate: false});
const hosts = new Map<string, WebSocket>();
const links = new Map<string, {host: WebSocket; client: WebSocket}>();
const perIp = new Map<string, number>();
function send(ws: WebSocket, value: unknown) {
  if (ws.readyState !== WebSocket.OPEN) return;
  if (ws.bufferedAmount > 8 * 1024 * 1024) { ws.terminate(); return; }
  ws.send(JSON.stringify(value));
}
server.on('upgrade', (req, socket, head) => {
  const ip = req.socket.remoteAddress ?? 'unknown';
  // Demo 不接收浏览器请求，也不相信可伪造的 X-Forwarded-For。
  if (req.url !== '/relay' || req.headers.origin || wss.clients.size >= 128 || (perIp.get(ip) ?? 0) >= 32) {
    socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return;
  }
  wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req));
});
wss.on('connection', (ws, req) => {
  const ip = req.socket.remoteAddress ?? 'unknown';
  perIp.set(ip, (perIp.get(ip) ?? 0) + 1);
  let hostKey: string | undefined;
  let clientLink: string | undefined;
  let registered = false;
  let alive = true;
  let messages = 0;
  const deadline = setTimeout(() => ws.terminate(), 10_000);
  const heartbeat = setInterval(() => {
    messages = 0;
    if (!alive) { ws.terminate(); return; }
    alive = false; ws.ping();
  }, 20_000);
  ws.on('pong', () => { alive = true; });
  ws.on('error', () => ws.terminate());
  ws.on('message', (raw, binary) => {
    try {
      if (binary || ++messages > 4096) throw new Error('LIMIT');
      const frame = JSON.parse(raw.toString());
      if (!registered) {
        if (frame.type === 'register' && typeof frame.token === 'string' && equal(frame.token, token)) {
          hostKey = key(frame.host);
          if (hosts.has(hostKey)) throw new Error('HOST_ALREADY_ONLINE');
          hosts.set(hostKey, ws); send(ws, {type: 'registered'});
        } else if (frame.type === 'join') {
          const host = hosts.get(key(frame.host));
          const client = key(frame.client);
          if (!host || [...links.values()].filter(link => link.host === host).length >= 8) throw new Error('HOST_UNAVAILABLE');
          clientLink = randomUUID(); links.set(clientLink, {host, client: ws});
          send(host, {type: 'open', id: clientLink, client});
          send(ws, {type: 'ready', id: clientLink});
        } else throw new Error('AUTH_REQUIRED');
        registered = true; clearTimeout(deadline); return;
      }
      const link = links.get(frame.id);
      // 关闭与在途消息会交叉：过期连接的关闭必须幂等，不能因此踢掉整台 Host。
      if (!link && (frame.type === 'close' || (hostKey && frame.type === 'packet'))) return;
      if (!link || (link.host !== ws && link.client !== ws)) throw new Error('UNKNOWN_LINK');
      const other = link.host === ws ? link.client : link.host;
      if (frame.type === 'packet' && typeof frame.data === 'string' && frame.data.length <= 90_000) {
        send(other, {type: 'packet', id: frame.id, data: frame.data});
      } else if (frame.type === 'close') {
        links.delete(frame.id); send(other, {type: 'closed', id: frame.id});
        if (link.client !== ws) link.client.close();
      } else throw new Error('INVALID_FRAME');
    } catch {
      // 绝不回显帧、令牌或服务端异常文本。
      send(ws, {type: 'error', code: 'RELAY_REJECTED'}); ws.close(1008, 'RELAY_REJECTED');
    }
  });
  ws.on('close', () => {
    clearTimeout(deadline); clearInterval(heartbeat);
    const count = (perIp.get(ip) ?? 1) - 1;
    if (count > 0) perIp.set(ip, count); else perIp.delete(ip);
    if (hostKey && hosts.get(hostKey) === ws) hosts.delete(hostKey);
    for (const [id, link] of links) {
      if (link.host !== ws && link.client !== ws) continue;
      links.delete(id);
      send(link.host === ws ? link.client : link.host, {type: 'closed', id});
      if (link.host === ws) link.client.close();
    }
  });
});
server.listen(Number(process.env.PORT ?? 8080), process.env.BIND ?? '127.0.0.1', () => {
  const address = server.address();
  console.log(`Codex Go Relay 已启动，端口 ${typeof address === 'object' ? address?.port : '?'}；公网入口请配置 HTTPS/WSS 反向代理。`);
});
