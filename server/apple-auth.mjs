// Optional Sign in with Apple web broker. Deploy only after a Services ID and
// exact HTTPS callback are registered. Never use client-decoded JWTs as auth.
const APPLE_ISSUER = 'https://appleid.apple.com';
const MAX_BODY = 16_384;
const b64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const decode = text => Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
const encodeJSON = value => b64(new TextEncoder().encode(JSON.stringify(value)));
const random = () => b64(crypto.getRandomValues(new Uint8Array(32)));
const hash = async value => b64(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
const json = (status, body) => Response.json(body, {status, headers: {'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff'}});
const redirect = url => new Response(null, {status: 302, headers: {Location: url, 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer'}});
const safeToken = (text, minimum = 16, maximum = 128) => typeof text === 'string' && text.length >= minimum && text.length <= maximum && /^[A-Za-z0-9_-]+$/.test(text);

async function bodyText(request) {
  if (Number(request.headers.get('Content-Length')) > MAX_BODY) throw new Error('body');
  const reader = request.body?.getReader();
  if (!reader) return '';
  let bytes = 0, chunks = '';
  const decoder = new TextDecoder();
  while (true) {
    const {value, done} = await reader.read();
    if (done) break;
    bytes += value.byteLength;
    if (bytes > MAX_BODY) { await reader.cancel(); throw new Error('body'); }
    chunks += decoder.decode(value, {stream: true});
  }
  return chunks + decoder.decode();
}
function configured(env) {
  if (!env.APPLE_SERVICE_ID || !env.APPLE_TEAM_ID || !env.APPLE_KEY_ID || !env.APPLE_PRIVATE_KEY) return false;
  try { return new URL(env.APPLE_AUTH_CALLBACK_URL).protocol === 'https:'; } catch { return false; }
}
function appCallback(state, values) {
  const url = new URL('soundbound://auth');
  url.searchParams.set('state', state);
  for (const [key, value] of Object.entries(values)) url.searchParams.set(key, value);
  return url.href;
}
export async function createAppleClientSecret(env, now = Date.now()) {
  const seconds = Math.floor(now / 1000);
  const header = encodeJSON({alg: 'ES256', kid: env.APPLE_KEY_ID});
  const payload = encodeJSON({iss: env.APPLE_TEAM_ID, sub: env.APPLE_SERVICE_ID, aud: APPLE_ISSUER, iat: seconds, exp: seconds + 300});
  const keyBytes = decode(env.APPLE_PRIVATE_KEY.replace(/-----[^-]+-----|\s/g, '').replace(/\+/g, '-').replace(/\//g, '_'));
  const key = await crypto.subtle.importKey('pkcs8', keyBytes, {name: 'ECDSA', namedCurve: 'P-256'}, false, ['sign']);
  const signature = await crypto.subtle.sign({name: 'ECDSA', hash: 'SHA-256'}, key, new TextEncoder().encode(`${header}.${payload}`));
  return `${header}.${payload}.${b64(signature)}`;
}
export async function verifyAppleIdentityToken(token, {audience, nonce, now = Date.now()}, upstream = fetch) {
  if (typeof token !== 'string' || token.length > 32_768) throw new Error('token');
  const parts = token.split('.');
  if (parts.length !== 3) throw new Error('token');
  const header = JSON.parse(new TextDecoder().decode(decode(parts[0])));
  if (header.alg !== 'RS256' || !safeToken(header.kid, 1, 128)) throw new Error('algorithm');
  const keysResponse = await upstream(`${APPLE_ISSUER}/auth/keys`, {redirect: 'error'});
  if (!keysResponse.ok) throw new Error('keys');
  const {keys} = await keysResponse.json();
  const jwk = keys?.find(key => key.kid === header.kid && key.kty === 'RSA' && (!key.alg || key.alg === 'RS256'));
  if (!jwk) throw new Error('key');
  const publicKey = await crypto.subtle.importKey('jwk', jwk, {name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256'}, false, ['verify']);
  if (!await crypto.subtle.verify('RSASSA-PKCS1-v1_5', publicKey, decode(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`))) throw new Error('signature');
  const claims = JSON.parse(new TextDecoder().decode(decode(parts[1])));
  const seconds = Math.floor(now / 1000);
  if (claims.iss !== APPLE_ISSUER || claims.aud !== audience || claims.nonce !== nonce ||
      !Number.isFinite(claims.exp) || claims.exp <= seconds ||
      !Number.isFinite(claims.iat) || claims.iat > seconds + 60 ||
      typeof claims.sub !== 'string' || claims.sub.length === 0 || claims.sub.length > 255) throw new Error('claims');
  return claims;
}

/** storage must provide Durable Object transaction/get/put/delete semantics. */
export async function handleAppleAuth(request, env, storage, dependencies = {}) {
  const upstream = dependencies.fetch ?? fetch;
  const now = dependencies.now ?? Date.now();
  const randomToken = dependencies.random ?? random;
  const url = new URL(request.url);
  if (url.pathname === '/apple/health') return json(200, {service: 'soundbound-apple-auth', configured: configured(env)});
  if (!configured(env)) return json(503, {error: 'Apple web sign-in is not configured'});
  try {
    if (url.pathname === '/apple/start' && request.method === 'GET') {
      const clientState = url.searchParams.get('state'), nonce = url.searchParams.get('nonce'), challenge = url.searchParams.get('code_challenge');
      if (!safeToken(clientState) || !safeToken(nonce) || !safeToken(challenge, 43, 43)) return json(400, {error: 'Invalid sign-in request'});
      // Global prototype limit bounds stored flows. It is not a hosting bill cap.
      const day = Math.floor(now / 86_400_000);
      const allowed = await storage.transaction(async tx => {
        const key = `limit:${day}`, record = await tx.get(key);
        if ((record?.count ?? 0) >= 1000) return false;
        await tx.put(key, {count: (record?.count ?? 0) + 1, expires: (day + 2) * 86_400_000});
        return true;
      });
      if (!allowed) return json(429, {error: 'Sign-in limit reached. Try tomorrow.'});
      const state = randomToken();
      await storage.put(`flow:${state}`, {clientState, nonce, challenge, expires: now + 600_000});
      const authorize = new URL(`${APPLE_ISSUER}/auth/authorize`);
      for (const [key, value] of Object.entries({client_id: env.APPLE_SERVICE_ID, redirect_uri: env.APPLE_AUTH_CALLBACK_URL,
        response_type: 'code', response_mode: 'form_post', scope: 'name email', state, nonce})) authorize.searchParams.set(key, value);
      return redirect(authorize.href);
    }
    if (url.pathname === '/apple/callback' && request.method === 'POST') {
      if (!request.headers.get('Content-Type')?.startsWith('application/x-www-form-urlencoded')) return json(415, {error: 'Unsupported callback'});
      const form = new URLSearchParams(await bodyText(request));
      const state = form.get('state');
      if (!safeToken(state)) return json(400, {error: 'Invalid callback'});
      const flow = await storage.transaction(async tx => {
        const record = await tx.get(`flow:${state}`);
        await tx.delete(`flow:${state}`);
        return record;
      });
      if (!flow || flow.expires <= now) return json(400, {error: 'Sign-in expired. Start again in Soundbound.'});
      if (form.has('error')) return redirect(appCallback(flow.clientState, {error: 'cancelled'}));
      const code = form.get('code');
      if (typeof code !== 'string' || code.length < 1 || code.length > 4096) return redirect(appCallback(flow.clientState, {error: 'invalid_response'}));
      try {
        const secret = await createAppleClientSecret(env, now);
        const tokenResponse = await upstream(`${APPLE_ISSUER}/auth/token`, {method: 'POST', redirect: 'error',
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: new URLSearchParams({grant_type: 'authorization_code', code, client_id: env.APPLE_SERVICE_ID,
            client_secret: secret, redirect_uri: env.APPLE_AUTH_CALLBACK_URL}).toString()});
        if (!tokenResponse.ok) throw new Error('exchange');
        const tokens = await tokenResponse.json();
        const claims = await verifyAppleIdentityToken(tokens.id_token, {audience: env.APPLE_SERVICE_ID, nonce: flow.nonce, now}, upstream);
        let name;
        try {
          const user = JSON.parse(form.get('user') ?? '{}');
          name = [user.name?.firstName, user.name?.lastName].filter(value => typeof value === 'string').join(' ').slice(0, 120) || undefined;
        } catch { /* Profile display name is optional. */ }
        const redemption = randomToken();
        const verifiedEmail = claims.email_verified === true || claims.email_verified === 'true';
        await storage.put(`redeem:${redemption}`, {challenge: flow.challenge, expires: now + 60_000,
          profile: {provider: 'apple', subject: claims.sub, name, email: verifiedEmail ? claims.email : undefined,
            expiresAt: Math.min(claims.exp, Math.floor(now / 1000) + 3600)}});
        // Apple's ID/access/refresh tokens are deliberately not stored or returned.
        return redirect(appCallback(flow.clientState, {code: redemption}));
      } catch { return redirect(appCallback(flow.clientState, {error: 'verification_failed'})); }
    }
    if (url.pathname === '/apple/redeem' && request.method === 'POST') {
      if (!request.headers.get('Content-Type')?.startsWith('application/json')) return json(415, {error: 'Use JSON'});
      const input = JSON.parse(await bodyText(request));
      if (!safeToken(input.code) || !safeToken(input.code_verifier, 43, 128)) return json(400, {error: 'Invalid redemption'});
      const challenge = await hash(input.code_verifier);
      const record = await storage.transaction(async tx => {
        const item = await tx.get(`redeem:${input.code}`);
        if (!item || item.expires <= now) { await tx.delete(`redeem:${input.code}`); return null; }
        if (item.challenge !== challenge) return null;
        await tx.delete(`redeem:${input.code}`);
        return item;
      });
      if (!record) return json(401, {error: 'Sign-in code is invalid or expired'});
      return json(200, record.profile);
    }
    return json(404, {error: 'Not found'});
  } catch { return json(400, {error: 'Invalid sign-in request'}); }
}

export class AppleAuthBroker {
  constructor(state, env) { this.state = state; this.env = env; }
  async fetch(request) {
    const response = await handleAppleAuth(request, this.env, this.state.storage);
    // Continuous requests must not postpone expiry cleanup indefinitely.
    if (await this.state.storage.getAlarm() === null) {
      await this.state.storage.setAlarm(Date.now() + 600_000);
    }
    return response;
  }
  async alarm() {
    const entries = await this.state.storage.list();
    const now = Date.now();
    const expired = [...entries].filter(([, value]) => value.expires <= now).map(([key]) => key);
    if (expired.length) await this.state.storage.delete(expired);
    if (entries.size > expired.length) await this.state.storage.setAlarm(now + 600_000);
  }
}
export default {
  fetch(request, env) {
    const url = new URL(request.url);
    const allowed = (request.method === 'GET' && ['/apple/start', '/apple/health'].includes(url.pathname)) ||
      (request.method === 'POST' && ['/apple/callback', '/apple/redeem'].includes(url.pathname));
    if (!allowed || url.href.length > 2048) return json(404, {error: 'Not found'});
    if (Number(request.headers.get('Content-Length')) > MAX_BODY) return json(413, {error: 'Request too large'});
    if (url.pathname === '/apple/health') return json(200, {service: 'soundbound-apple-auth', configured: configured(env)});
    if (!env.APPLE_AUTH) return json(503, {error: 'Apple web sign-in is not configured'});
    return env.APPLE_AUTH.get(env.APPLE_AUTH.idFromName('broker')).fetch(request);
  },
};
