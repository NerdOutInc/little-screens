import type { ConnectorBinding } from './lib/connector-contract.mjs';
import siteHandler from './build/sites-worker';
import { handleAPI, handleDevice, privateHeaders } from './server/service';

// Firmware/image responses bypass the HTML framework so their fixed byte length
// survives unchanged. The OG setup downloader requires Content-Length.
export default {
  async fetch(request: Request, env: Cloudflare.Env, ctx: ExecutionContext<{ CONNECTORS?: ConnectorBinding }>) {
    const url = new URL(request.url);
    let segments: string[];
    try { segments = url.pathname.split('/').filter(Boolean).map(decodeURIComponent); }
    catch { return new Response('', { status: 404, headers: privateHeaders }); }
    if (segments[0] === 'd') return handleDevice(request, segments.slice(1));
    if (segments[0] === 'api') return handleAPI(request, segments.slice(1));
    if (url.pathname === '/render') return handleAPI(request, ['assets', url.searchParams.get('id') ?? '', 'image']);
    const response = await siteHandler.fetch(request, env, ctx);
    if (url.pathname !== '/') return response;
    const headers = new Headers(response.headers);
    for (const [name, value] of Object.entries(privateHeaders)) headers.set(name, value);
    return new Response(response.body, { status: response.status, headers });
  }
};
