// Single-owner development credential issuer. Device enrollment and per-route
// grants belong in the control plane before any multi-user deployment.
const TTL_SECONDS = 600;

function reply(status, body) {
  return Response.json(body, {status, headers: {
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  }});
}

async function equalSecrets(left, right) {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([left, right].map(value =>
    crypto.subtle.digest('SHA-256', encoder.encode(value))));
  const first = new Uint8Array(a), second = new Uint8Array(b);
  let difference = 0;
  for (let i = 0; i < first.length; i++) difference |= first[i] ^ second[i];
  return difference === 0;
}

export async function handleRequest(request, env, upstream = fetch) {
  const url = new URL(request.url);
  if (url.pathname === '/health' && request.method === 'GET') {
    return reply(200, {service: 'soundbound-turn-issuer', status: 'ok'});
  }
  if (url.pathname !== '/turn/credentials') return reply(404, {error: 'Not found'});
  if (request.method !== 'POST') return reply(405, {error: 'Use POST'});
  if (!env.SOUNDBOUND_ACCESS_TOKEN || env.SOUNDBOUND_ACCESS_TOKEN.length < 32) {
    return reply(503, {error: 'Credential issuer is not configured'});
  }
  const bearer = request.headers.get('Authorization') ?? '';
  if (!bearer.startsWith('Bearer ') || !await equalSecrets(bearer.slice(7), env.SOUNDBOUND_ACCESS_TOKEN)) {
    return reply(401, {error: 'Unauthorized'});
  }
  if (!env.TURN_KEY_ID || !env.TURN_API_TOKEN || !/^[A-Za-z0-9_-]+$/.test(env.TURN_KEY_ID)) {
    return reply(503, {error: 'TURN is not configured'});
  }
  try {
    const result = await upstream(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`,
      {method: 'POST', headers: {
        'Authorization': `Bearer ${env.TURN_API_TOKEN}`,
        'Content-Type': 'application/json',
      }, body: JSON.stringify({ttl: TTL_SECONDS})});
    if (!result.ok) return reply(502, {error: 'TURN credential service unavailable'});
    const body = await result.json();
    if (!Array.isArray(body.iceServers) || body.iceServers.length === 0) {
      return reply(502, {error: 'Invalid TURN service response'});
    }
    // Return only the documented ICE credential fields, never an upstream token
    // or debug response. Production clients force relay candidates in phase one.
    const iceServers = body.iceServers.map(server => {
      const urls = Array.isArray(server.urls) ? server.urls : [server.urls];
      if (!urls.length || urls.some(value => typeof value !== 'string' ||
        !/^(stun:stun|turns?:turn)\.cloudflare\.com:\d+(\?transport=(udp|tcp))?$/.test(value))) {
        throw new Error('Unexpected ICE endpoint');
      }
      const result = {urls};
      if (urls.some(value => value.startsWith('turn'))) {
        if (typeof server.username !== 'string' || typeof server.credential !== 'string') {
          throw new Error('Missing relay credentials');
        }
        result.username = server.username;
        result.credential = server.credential;
      }
      return result;
    });
    return reply(200, {iceServers, expiresAt: new Date(Date.now() + TTL_SECONDS * 1000).toISOString(),
      iceTransportPolicy: 'relay'});
  } catch {
    return reply(502, {error: 'TURN credential service unavailable'});
  }
}

export default {fetch(request, env) { return handleRequest(request, env); }};
