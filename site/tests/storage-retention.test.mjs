import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import ts from 'typescript';
const require = createRequire(import.meta.url);
const day = 86400000, hour = 3600000;
function load(file, mocks = {}) {
  const module = { exports: {} };
  const js = ts.transpileModule(readFileSync(new URL('../server/' + file + '.ts', import.meta.url), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  new Function('require', 'module', 'exports', js)(name => mocks[name] ?? require(name), module, module.exports);
  return module.exports;
}
const retention = load('retention');
const key = (n, kind = 'screens', id = '0123456789ab') => `${kind}/${id}/${String(n).padStart(64, '0')}.png`;
function fixture() {
  const time = Date.now(), id = '0123456789ab', current = { id: 'live', key: key(1), sha256: '1', created_at: new Date(time - 2 * day).toISOString(), metadata: {}, instructions_revision: 1 };
  const screen = { id, name: 'Example', instructions: 'Keep preferences', refresh_seconds: 300, revision: 10, active: true, created_at: current.created_at, updated_at: current.created_at, profile: { timezone: 'UTC' }, publication: current, publications: [{ ...current, key: key(4) }, current], scene: { key: key(2, 'scenes'), reference_key: key(3, 'scenes'), date: '2026-01-01', character: 'Example', identity: 'Example identity' } };
  const state = { screens: { [id]: screen }, receipts: {} };
  const objects = new Map([1, 2, 3, 4, 5, 6].map(n => [key(n, n === 2 || n === 3 ? 'scenes' : 'screens'), { uploaded: new Date(time - (n === 6 ? 0 : 2 * day)) }]));
  objects.set('unrelated/example.png', { uploaded: new Date(0) });
  let version = 1, data = JSON.stringify(state), failList = false;
  const DB = { prepare(sql) { let values = []; return { bind(...v) { values = v; return this; }, async run() { if (sql.startsWith('UPDATE registry')) { if (values[1] !== version) return { meta: { changes: 0 } }; data = values[0]; version++; } return { meta: { changes: 1 } }; }, async first() { if (sql.includes('SELECT version')) return { version, data }; return null; } }; } };
  const BUCKET = { async list() { if (failList) throw new Error('offline'); return { objects: [...objects].map(([key, value]) => ({ key, ...value })), truncated: false }; }, async delete(keys) { for (const k of keys) objects.delete(k); } };
  const env = { DB, BUCKET, SITE_TOKEN: 'a'.repeat(40), SITE_ORIGIN: 'https://example.test' };
  const service = load('service', { 'cloudflare:workers': { env }, './guide': { GUIDE: '', DEFAULT_INSTRUCTIONS: '' }, './retention': retention });
  const post = async (action, body, auth = true) => service.handleAPI(new Request('https://example.test/api/' + action, { method: 'POST', headers: { 'content-type': 'application/json', ...(auth ? { authorization: 'Bearer ' + env.SITE_TOKEN } : {}) }, body: JSON.stringify(body) }), [action]);
  return { id, time, screen, objects, post, get state() { return JSON.parse(data); }, set state(v) { data = JSON.stringify(v); }, failList() { failList = true; } };
}
test('expires only one-day-old receipts, conservatively migrates legacy timestamps', () => {
  const time = Date.now(), date = n => new Date(time - n).toISOString();
  const state = { screens: {}, receipts: { old: { digest: 'a', result: {} }, dated: { digest: 'b', result: { publication: { created_at: date(2 * day) } } }, recent: { digest: 'c', result: {}, created_at: date(hour) }, tail: { digest: 'd', result: {} } } };
  retention.pruneHistory(state, time);
  assert.deepEqual(Object.keys(state.receipts), ['recent', 'tail']);
  retention.pruneHistory(state, time + day + 1);
  assert.equal(Object.keys(state.receipts).length, 0);
});
test('repairs an oversized registry and preserves live pixels, settings and reference', async () => {
  const f = fixture(), state = f.state;
  for (let n = 0; n < 2000; n++) state.receipts['old' + n] = { digest: 'a', result: { padding: 'x'.repeat(900) }, created_at: new Date(f.time - 2 * day).toISOString() };
  f.state = state; assert.ok(JSON.stringify(state).length > 1500000);
  const response = await f.post('maintain_storage', { request_id: crypto.randomUUID() });
  assert.equal(response.status, 200);const result = await response.json();
  assert.equal(result.receipts_removed, 2000);assert.equal(result.images_deleted, 2);
  assert.deepEqual(f.state.screens[f.id].profile, f.screen.profile);assert.equal(f.state.screens[f.id].revision, 10);
  for (const k of [key(1), key(2, 'scenes'), key(3, 'scenes'), key(6), 'unrelated/example.png']) assert.ok(f.objects.has(k));
  assert.equal(f.objects.has(key(4)), false);assert.equal(f.objects.has(key(5)), false);
});
test('identical retries commit once, changed input and stale revisions conflict', async () => {
  const f = fixture(), request_id = crypto.randomUUID();
  const body = { request_id, expected_revision: 10, id: f.id, name: 'Example', instructions: 'Keep preferences', refresh_seconds: 300, active: true, profile: f.screen.profile };
  const a = await f.post('save_screen', body);assert.equal(a.status, 200);const first = await a.json();
  const b = await f.post('save_screen', body);assert.deepEqual(await b.json(), first);assert.equal(f.state.screens[f.id].revision, 11);
  assert.equal((await f.post('save_screen', { ...body, name: 'Changed' })).status, 409);
  assert.equal((await f.post('save_screen', { ...body, request_id: crypto.randomUUID() })).status, 409);
  assert.equal((await f.post('maintain_storage', { request_id: crypto.randomUUID() }, false)).status, 404);
});
test('an active cleanup lease prevents writes and cleanup failure releases its lease', async () => {
  const f = fixture(), state = f.state;state.cleanup = { lease: 'other', until: Date.now() + 60000 };f.state = state;
  assert.equal((await f.post('maintain_storage', { request_id: crypto.randomUUID() })).status, 503);
  delete state.cleanup;f.state = state;f.failList();
  assert.equal((await f.post('maintain_storage', { request_id: crypto.randomUUID() })).status, 503);
  assert.equal(f.state.cleanup?.lease, undefined);assert.equal(f.state.screens[f.id].publication.key, key(1));
});
