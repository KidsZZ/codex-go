// 中转只承载控制帧与密文；身份认证和配对授权全部由两端完成。
import { timingSafeEqual } from 'node:crypto';
import { NoiseIkSession } from './noise.js';

export const MAX_MESSAGE = 4 * 1024 * 1024;
export const MAX_FRAME = 96 * 1024;
export const KEY = /^[A-Za-z0-9_-]{43}$/;
export function fromBase64Url(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/.test(value)) throw new Error('INVALID_ENCODING');
  const bytes = Buffer.from(value, 'base64url');
  if (bytes.toString('base64url') !== value) throw new Error('INVALID_ENCODING');
  return bytes;
}
export function key(value: unknown): string {
  if (typeof value !== 'string' || !KEY.test(value) || fromBase64Url(value).length !== 32) {
    throw new Error('INVALID_KEY');
  }
  return value;
}
export function equal(left: string, right: string): boolean {
  const a = Buffer.from(left); const b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
}
export function relayUrl(value: string): string {
  const url = new URL(value);
  if (url.username || url.password || url.search || url.hash || !/^\/(?:[A-Za-z0-9_-]+\/)*relay$/.test(url.pathname) ||
      (url.protocol !== 'wss:' && !(url.protocol === 'ws:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)))) {
    throw new Error('Relay 必须使用 wss://域名/relay；仅本机调试允许 ws。');
  }
  return url.toString();
}
export function prologue(id: string, host: string, client: string): Uint8Array {
  if (!/^[a-f0-9-]{36}$/.test(id)) throw new Error('INVALID_CONNECTION');
  return Buffer.from(`CODEX-GO\0v=1\0connection=${id}\0host=${key(host)}\0client=${key(client)}`);
}

// 大消息分片后分别加密，终止标记同样被认证；最多缓存一条 4 MiB 消息。
export class SecureMessages {
  private chunks: Uint8Array[] = [];
  private size = 0;
  constructor(readonly noise: NoiseIkSession) {}
  encode(value: unknown): string[] {
    const bytes = Buffer.from(JSON.stringify(value));
    if (bytes.length > MAX_MESSAGE) throw new Error('MESSAGE_TOO_LARGE');
    const frames: string[] = [];
    for (let offset = 0; offset < bytes.length; offset += 48 * 1024) {
      const end = Math.min(offset + 48 * 1024, bytes.length);
      frames.push(Buffer.from(this.noise.encrypt(Buffer.concat([
        Buffer.from([end === bytes.length ? 1 : 0]), bytes.subarray(offset, end),
      ]))).toString('base64url'));
    }
    return frames;
  }
  decode(data: string): Record<string, unknown> | undefined {
    const bytes = this.noise.decrypt(fromBase64Url(data));
    if (bytes.length < 2 || bytes[0]! > 1) throw new Error('INVALID_FRAGMENT');
    this.size += bytes.length - 1;
    if (this.size > MAX_MESSAGE) throw new Error('MESSAGE_TOO_LARGE');
    this.chunks.push(bytes.subarray(1));
    if (!bytes[0]) return;
    const value: unknown = JSON.parse(Buffer.concat(this.chunks).toString('utf8'));
    this.chunks = []; this.size = 0;
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('INVALID_MESSAGE');
    return value as Record<string, unknown>;
  }
}
