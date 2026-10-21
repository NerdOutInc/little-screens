// Receipts only promise idempotent replay for one day. Images use a short
// fetch grace period; the live publication, scene, and daily reference never expire.
export const RECEIPT_TTL_MS = 24 * 60 * 60 * 1000;
export const IMAGE_GRACE_MS = 60 * 60 * 1000;
export type Receipt = { digest: string; result: unknown; created_at?: string };
export type RetainedState = {
  screens: Record<string, { publication?: { key: string; created_at: string }; publications?: { key: string; created_at: string }[]; scene?: { key: string; reference_key: string } }>;
  receipts: Record<string, Receipt>;
};
export function pruneHistory(state: RetainedState, time: number) {
  let receiptsRemoved = 0, publicationsRemoved = 0;
  // Old receipts had no timestamp. In insertion order, the next dated
  // publication is a conservative upper bound on their commit time. Keep an
  // undated tail for at most one migration day, rather than dropping retry safety.
  let upperBound = time;
  for (const id of Object.keys(state.receipts).reverse()) {
    const receipt = state.receipts[id];
    const dated = receipt.result as { publication?: { created_at?: string } };
    const explicit = Date.parse(receipt.created_at ?? dated?.publication?.created_at ?? '');
    if (Number.isFinite(explicit)) upperBound = Math.min(upperBound, explicit);
    const created = Number.isFinite(explicit) ? explicit : upperBound;
    receipt.created_at = new Date(created).toISOString();
    if (created <= time - RECEIPT_TTL_MS) { delete state.receipts[id]; receiptsRemoved++; }
  }
  for (const screen of Object.values(state.screens)) {
    if (!screen.publications) continue;
    const old = screen.publications;
    screen.publications = old.filter(p => p.key === screen.publication?.key || Date.parse(p.created_at) > time - IMAGE_GRACE_MS);
    publicationsRemoved += old.length - screen.publications.length;
  }
  return { receipts_removed: receiptsRemoved, publications_removed: publicationsRemoved };
}
export function protectedImageKeys(state: RetainedState) {
  const keys = new Set<string>();
  for (const screen of Object.values(state.screens)) {
    if (screen.publication) keys.add(screen.publication.key);
    for (const publication of screen.publications ?? []) keys.add(publication.key);
    if (screen.scene) { keys.add(screen.scene.key); keys.add(screen.scene.reference_key); }
  }
  return keys;
}
export function ownedImageKey(key: string) { return /^(screens|scenes)\/[a-f0-9]{12}\/[a-f0-9]{64}\.png$/.test(key); }
