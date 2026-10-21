import { env } from 'cloudflare:workers';
import { z } from 'zod';
import { GUIDE, DEFAULT_INSTRUCTIONS } from './guide';
import { IMAGE_GRACE_MS, pruneHistory, protectedImageKeys, ownedImageKey, type Receipt } from './retention';

export const privateHeaders = { 'Cache-Control': 'private, no-store', 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff', 'X-Robots-Tag': 'noindex, nofollow' };
export const json = (value: unknown, status = 200) => Response.json(value, { status, headers: privateHeaders });
export const missing = () => new Response('', { status: 404, headers: privateHeaders });
class Problem extends Error { constructor(public status: number, message: string) { super(message); } }
export function tokenOK(token?: string | null) {
  const secret = env.SITE_TOKEN;
  if (!secret || secret.length < 32 || !token || token.length !== secret.length) return false;
  let delta = 0; for (let i = 0; i < secret.length; i++) delta |= secret.charCodeAt(i) ^ token.charCodeAt(i);
  return delta === 0;
}
export function authorized(request: Request) { return tokenOK(request.headers.get('authorization')?.replace(/^Bearer /, '')) || tokenOK(new URL(request.url).searchParams.get('token')); }
const db = () => { if (!env.DB) throw new Problem(503, 'Storage unavailable'); return env.DB; };
const bucket = () => { if (!env.BUCKET) throw new Problem(503, 'Image storage unavailable'); return env.BUCKET; };
const now = () => new Date().toISOString();
const origin = () => { if (!env.SITE_ORIGIN) throw new Problem(503, 'Site origin unavailable'); return env.SITE_ORIGIN.replace(/\/$/, ''); };
const digest = async (input: string | Uint8Array) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', typeof input === 'string' ? new TextEncoder().encode(input) : input as BufferSource))).map(b => b.toString(16).padStart(2, '0')).join('');
const textField = (length: number) => z.string().trim().min(1).max(length);
const objectValue = z.record(z.unknown());
type Publication = { id: string; key: string; sha256: string; created_at: string; instructions_revision: number; metadata: Record<string, unknown> };
type Scene = { date: string; character: string; identity: string; condition: string; phase: string; prompt: string; key: string; reference_key: string; replacement?: { reason: string; at: string } };
export type Screen = { id: string; name: string; instructions: string; refresh_seconds: number; revision: number; active: boolean; created_at: string; updated_at: string; publication?: Publication; publications?: Publication[]; scene?: Scene; profile: Record<string, unknown> };
type State = { screens: Record<string, Screen>; receipts: Record<string, Receipt>; cleanup?: { lease?: string; until?: number; cursor?: string } };
async function load() {
  await db().prepare("INSERT OR IGNORE INTO registry(id, version, data) VALUES('main', 0, ?)").bind(JSON.stringify({ screens: {}, receipts: {} })).run();
  const row = await db().prepare("SELECT version, data FROM registry WHERE id = 'main'").first<{version: number; data: string}>();
  if (!row) throw new Problem(503, 'Registry unavailable');
  return { version: row.version, state: JSON.parse(row.data) as State };
}
async function change(requestId: string, input: unknown, fn: (s: State) => unknown) {
  const hash = await digest(JSON.stringify(input));
  for (let attempt = 0; attempt < 5; attempt++) {
    const { version, state } = await load();
    if ((state.cleanup?.until ?? 0) > Date.now()) throw new Problem(503, 'Storage maintenance in progress; retry identical request');
    pruneHistory(state, Date.now());
    const receipt = state.receipts[requestId];
    if (receipt) { if (receipt.digest !== hash) throw new Problem(409, 'Request ID was already used with different input'); return receipt.result; }
    if (Object.keys(state.receipts).length >= 10000) throw new Problem(507, 'Receipt storage full; maintenance required before further writes');
    const result = fn(state);
    state.receipts[requestId] = { digest: hash, result, created_at: now() };
    const encoded = JSON.stringify(state);
    if (new TextEncoder().encode(encoded).length > 1500000) throw new Problem(507, 'Registry storage full');
    const write = await db().prepare("UPDATE registry SET data = ?, version = version + 1 WHERE id = 'main' AND version = ?").bind(encoded, version).run();
    if (write.meta.changes === 1) return result;
  }
  throw new Problem(409, 'Concurrent update; retry identical request');
}
// A short registry lease prevents publication commits while unreferenced objects
// are deleted. Uploads which race the lease cannot commit; an identical retry
// uploads their content again before committing. Cleanup never touches live keys.
async function maintainStorage() {
  const lease = crypto.randomUUID(), time = Date.now();
  let locked: State | undefined, stats: ReturnType<typeof pruneHistory> | undefined;
  for (let attempt = 0; attempt < 5; attempt++) {
    const { version, state } = await load();
    if ((state.cleanup?.until ?? 0) > time) throw new Problem(503, 'Storage maintenance in progress; retry identical request');
    stats = pruneHistory(state, time);
    state.cleanup = { ...state.cleanup, lease, until: time + 60000 };
    const write = await db().prepare("UPDATE registry SET data = ?, version = version + 1 WHERE id = 'main' AND version = ?").bind(JSON.stringify(state), version).run();
    if (write.meta.changes === 1) { locked = state; break; }
  }
  if (!locked || !stats) throw new Problem(409, 'Concurrent maintenance; retry identical request');
  let cursor = locked.cleanup?.cursor, deleted = 0, scanned = 0;
  try {
    const protectedKeys = protectedImageKeys(locked);
    const page = await bucket().list({ limit: 500, ...(cursor ? { cursor } : {}) });
    scanned = page.objects.length;
    const obsolete = page.objects.filter(item => ownedImageKey(item.key) && !protectedKeys.has(item.key) && item.uploaded.getTime() < time - IMAGE_GRACE_MS);
    for (let n = 0; n < obsolete.length; n += 100) {
      // D1's lease is bounded; abort deletion before it can expire.
      if (Date.now() >= time + 45000) throw new Problem(503, 'Image cleanup will resume on the next update');
      const keys = obsolete.slice(n, n + 100).map(item => item.key);
      await bucket().delete(keys); deleted += keys.length;
    }
    cursor = page.truncated ? page.cursor : undefined;
  } finally {
    for (let attempt = 0; attempt < 5; attempt++) {
      const { version, state } = await load();
      if (state.cleanup?.lease !== lease) break;
      state.cleanup = cursor ? { cursor } : {};
      const write = await db().prepare("UPDATE registry SET data = ?, version = version + 1 WHERE id = 'main' AND version = ?").bind(JSON.stringify(state), version).run();
      if (write.meta.changes === 1) break;
    }
  }
  return { ...stats, images_deleted: deleted, images_scanned: scanned, cleanup_pending: Boolean(cursor), receipt_retention_hours: 24, image_grace_hours: 1 };
}
const idSchema = z.string().regex(/^[a-f0-9]{12}$/);
const writeBase = { request_id: z.string().uuid(), expected_revision: z.number().int().min(0) };
function expect(s: State, id: string, revision: number) {
  const screen = s.screens[id];
  if (!screen) throw new Problem(404, 'Screen not found');
  if (screen.revision !== revision) throw new Problem(409, 'Screen changed; read it again before updating');
  return screen;
}
async function deviceKey(id: string) {
  if (!env.SITE_TOKEN || env.SITE_TOKEN.length < 32) throw new Problem(503, 'Token unavailable');
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(env.SITE_TOKEN), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return Array.from(new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode('device:' + id)))).slice(0, 16).map(b => b.toString(16).padStart(2, '0')).join('');
}
async function present(screen: Screen) {
  const base = origin() + '/d/' + screen.id + '/' + await deviceKey(screen.id);
  const status = await db().prepare('SELECT seen, image_sent, publication_id FROM checkins WHERE id = ?').bind(screen.id).first();
  return { ...screen, setup_url: base, image_url: screen.publication ? base + '/image/' + screen.publication.id + '.png' : null, status };
}
function crc32(data: Uint8Array) { let crc = -1; for (const b of data) { crc ^= b; for (let j = 0; j < 8; j++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); } return (crc ^ -1) >>> 0; }
async function png(input: string) {
  if (input.length > 120000 || !/^[A-Za-z0-9+/]*={0,2}$/.test(input)) throw new Problem(400, 'PNG exceeds 90,000 bytes or base64 is invalid');
  let bytes: Uint8Array; try { bytes = Uint8Array.from(atob(input), c => c.charCodeAt(0)); } catch { throw new Problem(400, 'Invalid base64'); }
  if (bytes.length > 90000 || bytes.length < 57 || Array.from(bytes.slice(0, 8)).join(',') !== '137,80,78,71,13,10,26,10') throw new Problem(400, 'Invalid PNG');
  const view = new DataView(bytes.buffer); let pos = 8, depth = 0, ended = false, hadIDAT = false; const chunks: Uint8Array[] = [];
  while (pos + 12 <= bytes.length) {
    const n = view.getUint32(pos); if (pos + n + 12 > bytes.length) throw new Problem(400, 'Truncated PNG');
    const type = String.fromCharCode(...bytes.slice(pos + 4, pos + 8));
    if (crc32(bytes.slice(pos + 4, pos + 8 + n)) !== view.getUint32(pos + 8 + n)) throw new Problem(400, 'PNG checksum mismatch');
    if (pos === 8) {
      if (type !== 'IHDR' || n !== 13 || view.getUint32(pos + 8) !== 800 || view.getUint32(pos + 12) !== 480 || ![1, 2].includes(bytes[pos + 16]) || bytes[pos + 17] !== 0 || bytes[pos + 18] !== 0 || bytes[pos + 19] !== 0 || bytes[pos + 20] !== 0) throw new Problem(400, 'Use 800×480 non-interlaced 1-bit or 2-bit grayscale PNG');
      depth = bytes[pos + 16];
    } else if (type === 'IDAT') { hadIDAT = true; chunks.push(bytes.slice(pos + 8, pos + 8 + n)); }
    else if (type === 'IEND' && n === 0) { pos += 12; ended = true; break; }
    else { throw new Problem(400, 'Only IHDR, IDAT, and IEND PNG chunks are accepted'); }
    pos += n + 12;
  }
  if (!ended || pos !== bytes.length || !hadIDAT) throw new Problem(400, 'Incomplete PNG');
  const packed = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0)); let offset = 0; for (const c of chunks) { packed.set(c, offset); offset += c.length; }
  const stream = new Blob([packed]).stream().pipeThrough(new DecompressionStream('deflate')); const reader = stream.getReader();
  const rowBytes = 800 * depth / 8 + 1, expected = rowBytes * 480; let read = 0;
  try {
    while (true) { const value = await reader.read(); if (value.done) break;
      for (let i = 0; i < value.value.length; i++) if ((read + i) % rowBytes === 0 && value.value[i] > 4) throw new Error('filter');
      read += value.value.length; if (read > expected) { await reader.cancel(); throw new Error('size'); }
    }
    if (read !== expected) throw new Error('size');
  } catch { throw new Problem(400, 'Invalid PNG pixel data'); }
  return bytes;
}
async function write(action: string, raw: unknown) {
  if (action === 'maintain_storage') {
    const a = z.object({ request_id: z.string().uuid() }).strict().parse(raw);
    const result = await maintainStorage();
    return change(a.request_id, { action, ...a }, () => ({ committed: true, ...result }));
  }
  if (action === 'save_screen') {
    const a = z.object({ ...writeBase, id: idSchema.optional(), name: textField(80), instructions: textField(12000), refresh_seconds: z.number().int().min(60).max(86400), active: z.boolean(), profile: objectValue.optional() }).strict().parse(raw);
    const id = a.id ?? crypto.randomUUID().replaceAll('-', '').slice(0, 12);
    return change(a.request_id, { action, ...a }, s => {
      if (a.id) { const screen = expect(s, id, a.expected_revision); Object.assign(screen, { name: a.name, instructions: a.instructions, refresh_seconds: a.refresh_seconds, active: a.active, profile: a.profile ?? screen.profile, revision: screen.revision + 1, updated_at: now() }); }
      else { if (a.expected_revision !== 0) throw new Problem(409, 'New screens require revision 0'); s.screens[id] = { id, name: a.name, instructions: a.instructions, refresh_seconds: a.refresh_seconds, active: a.active, profile: a.profile ?? {}, revision: 1, created_at: now(), updated_at: now() }; }
      return { committed: true, id, revision: s.screens[id].revision };
    });
  }
  if (action === 'publish_screen') {
    const a = z.object({ ...writeBase, id: idSchema, png_base64: z.string().max(120000), metadata: objectValue.default({}) }).strict().parse(raw);
    if (JSON.stringify(a.metadata).length > 16000) throw new Problem(400, 'Publication metadata too large');
    const bytes = await png(a.png_base64), sha256 = await digest(bytes), key = 'screens/' + a.id + '/' + sha256 + '.png';
    await bucket().put(key, bytes, { httpMetadata: { contentType: 'image/png' } });
    return change(a.request_id, { action, ...a }, s => {
      const screen = expect(s, a.id, a.expected_revision);
      if (!screen.active) throw new Problem(409, 'Screen is disconnected');
      const publication: Publication = { id: crypto.randomUUID(), key, sha256, created_at: now(), instructions_revision: screen.revision, metadata: a.metadata };
      screen.publications = [...(screen.publications ?? []), publication].filter(p => Date.parse(p.created_at) > Date.now() - IMAGE_GRACE_MS);
      screen.publication = publication; screen.revision += 1; screen.updated_at = now();
      return { committed: true, id: screen.id, revision: screen.revision, publication, physical_refresh_verified: false };
    });
  }
  if (action === 'save_scene') {
    const a = z.object({ ...writeBase, id: idSchema, date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), character: textField(60), identity: textField(500), condition: textField(45), phase: z.enum(['morning', 'afternoon', 'evening', 'night']), prompt: textField(3000), png_base64: z.string().max(120000), replace_daily_character: z.boolean().optional(), replacement_reason: textField(500).optional() }).strict().refine(a => Boolean(a.replace_daily_character) === Boolean(a.replacement_reason), { message: 'Explicit replacement requires both replace_daily_character=true and replacement_reason' }).parse(raw);
    const bytes = await png(a.png_base64), key = 'scenes/' + a.id + '/' + await digest(bytes) + '.png';
    await bucket().put(key, bytes, { httpMetadata: { contentType: 'image/png' } });
    return change(a.request_id, { action, ...a }, s => {
      const screen = expect(s, a.id, a.expected_revision), previous = screen.scene;
      if (previous && a.date < previous.date) throw new Problem(409, 'Cannot replace a newer daily scene');
      const sameDay = previous?.date === a.date;
      if (sameDay && (previous.character !== a.character || previous.identity !== a.identity) && !a.replace_daily_character) throw new Problem(409, 'Preserve the character identity for the whole day unless the owner explicitly requests a replacement');
      screen.scene = { date: a.date, character: a.character, identity: a.identity, condition: a.condition, phase: a.phase, prompt: a.prompt, key, reference_key: sameDay && !a.replace_daily_character ? previous.reference_key : key, ...(a.replace_daily_character ? { replacement: { reason: a.replacement_reason!, at: now() } } : sameDay && previous.replacement ? { replacement: previous.replacement } : {}) };
      screen.revision += 1; screen.updated_at = now();
      return { committed: true, id: a.id, revision: screen.revision, scene: screen.scene };
    });
  }
  throw new Problem(404, 'Unknown action');
}
export async function handleAPI(request: Request, path: string[]) {
  if (!authorized(request)) return missing();
  try {
    if (request.method === 'GET') {
      if (path.join('/') === 'guide') return json({ version: 1, guide: GUIDE, default_instructions: DEFAULT_INSTRUCTIONS });
      const { state } = await load();
      if (path[0] === 'screens' && path.length === 1) return json({ screens: await Promise.all(Object.values(state.screens).map(present)) });
      if (path[0] === 'screens' && path.length === 2 && state.screens[path[1]]) return json(await present(state.screens[path[1]]));
      if (path[0] === 'receipts') { pruneHistory(state, Date.now()); if (state.receipts[path[1]]) return json(state.receipts[path[1]].result); }
      if (path[0] === 'assets' && path.length === 3) {
        const screen = state.screens[path[1]];
        const key = path[2] === 'scene' ? screen?.scene?.key : path[2] === 'reference' ? screen?.scene?.reference_key : path[2] === 'image' ? screen?.publication?.key : undefined;
        if (key) return imageResponse(key);
      }
      return missing();
    }
    if (request.method !== 'POST' || path.length !== 1) return missing();
    const requestOrigin = request.headers.get('origin');
    if (requestOrigin && requestOrigin !== new URL(request.url).origin && requestOrigin !== origin()) return missing();
    if (!request.headers.get('content-type')?.startsWith('application/json')) return json({ error: 'Use application/json' }, 415);
    if (Number(request.headers.get('content-length') ?? 0) > 160000) throw new Problem(413, 'Request too large');
    const body = await request.text(); if (body.length > 160000) throw new Problem(413, 'Request too large');
    const raw = JSON.parse(body);
    if (['save_screen', 'save_scene', 'publish_screen'].includes(path[0])) await maintainStorage();
    return json(await write(path[0], raw));
  } catch (error) {
    if (error instanceof Problem) return json({ error: error.message }, error.status);
    if (error instanceof z.ZodError || error instanceof SyntaxError) return json({ error: 'Invalid request', details: error instanceof z.ZodError ? error.issues : undefined }, 400);
    return json({ error: 'Server could not complete the request; retry with the same request ID' }, 503);
  }
}
async function imageResponse(key: string) {
  const item = await bucket().get(key); if (!item) return missing();
  return new Response(await item.arrayBuffer(), { headers: { ...privateHeaders, 'Content-Type': 'image/png', 'Content-Length': String(item.size) } });
}
export async function handleDevice(request: Request, path: string[]) {
  try {
    const [id, key, ...route] = path;
    if (!idSchema.safeParse(id).success || !key || key !== await deviceKey(id)) return missing();
    const { state } = await load(), screen = state.screens[id];
    if (!screen?.active) return missing();
    const part = route.join('/');
    const base = origin() + '/d/' + id + '/' + key;
    if (request.method === 'GET' && (part === 'api/setup' || part === 'api/display')) {
      await db().prepare('INSERT INTO checkins(id, seen) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET seen=excluded.seen').bind(id, now()).run();
      if (!screen.publication) return json({ status: 202, message: 'Waiting for the first screen', refresh_rate: screen.refresh_seconds });
      const common = { image_url: base + '/image/' + screen.publication.id + '.png', filename: screen.publication.id + '.png', refresh_rate: screen.refresh_seconds, update_firmware: false, reset_firmware: false, special_function: 'sleep' };
      return json(part === 'api/setup' ? { status: 200, api_key: key, friendly_id: id.slice(0, 8).toUpperCase(), ...common } : { status: 0, ...common });
    }
    if (request.method === 'POST' && part === 'api/log') return json({ status: 200 });
    const requestedImage = (screen.publications ?? (screen.publication ? [screen.publication] : [])).find(p => part === 'image/' + p.id + '.png');
    if (request.method === 'GET' && requestedImage) {
      const response = await imageResponse(requestedImage.key);
      if (response.status === 200) await db().prepare('INSERT INTO checkins(id, image_sent, publication_id) VALUES(?, ?, ?) ON CONFLICT(id) DO UPDATE SET image_sent=excluded.image_sent, publication_id=excluded.publication_id').bind(id, now(), requestedImage.id).run();
      return response;
    }
    return missing();
  } catch { return json({ error: 'Temporarily unavailable' }, 503); }
}
