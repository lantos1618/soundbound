import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {handleRequest} from './worker.mjs';
globalThis.crypto ??= webcrypto;
const env = {SOUNDBOUND_ACCESS_TOKEN: 'development-test-token-at-least-32-characters',
  TURN_KEY_ID: 'test-key', TURN_API_TOKEN: 'test-api-token'};
function request(token = env.SOUNDBOUND_ACCESS_TOKEN, path = '/turn/credentials', method = 'POST') {
  return new Request(`https://example.invalid${path}`, {method, headers: {Authorization: `Bearer ${token}`}});
}
const credentials = {iceServers: [{urls: ['stun:stun.cloudflare.com:3478']},
  {urls: ['turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:443?transport=tcp'],
   username: 'temporary-user', credential: 'temporary-password'}]};

test('rejects unauthenticated requests before contacting Cloudflare', async () => {
  let called = false;
  const result = await handleRequest(request('wrong'), env, () => {called = true;});
  assert.equal(result.status, 401);
  assert.equal(called, false);
});
test('refuses an unconfigured issuer', async () => {
  assert.equal((await handleRequest(request(), {})).status, 503);
});
test('issues short-lived relay credentials without exposing the API token', async () => {
  const result = await handleRequest(request(), env, async (url, options) => {
    assert.equal(url, 'https://rtc.live.cloudflare.com/v1/turn/keys/test-key/credentials/generate-ice-servers');
    assert.equal(JSON.parse(options.body).ttl, 600);
    assert.equal(options.headers.Authorization, `Bearer ${env.TURN_API_TOKEN}`);
    return Response.json({...credentials, sensitiveDebugField: env.TURN_API_TOKEN});
  });
  assert.equal(result.status, 200);
  assert.equal(result.headers.get('Cache-Control'), 'no-store');
  const text = await result.text();
  assert.ok(!text.includes(env.TURN_API_TOKEN));
  const body = JSON.parse(text);
  assert.equal(body.iceTransportPolicy, 'relay');
  assert.deepEqual(body.iceServers, credentials.iceServers);
  assert.ok(Date.parse(body.expiresAt) > Date.now());
});
test('does not expose upstream failure details', async () => {
  const result = await handleRequest(request(), env, async () => new Response('secret failure detail', {status: 403}));
  assert.equal(result.status, 502);
  assert.ok(!(await result.text()).includes('secret'));
});
test('rejects arbitrary relay endpoints', async () => {
  const result = await handleRequest(request(), env, async () => Response.json({iceServers: [{urls: 'turn:untrusted.invalid:443'}]}));
  assert.equal(result.status, 502);
});
test('rejects unsupported method and path', async () => {
  assert.equal((await handleRequest(request(undefined, '/turn/credentials', 'GET'), env)).status, 405);
  assert.equal((await handleRequest(request(undefined, '/other'), env)).status, 404);
});
