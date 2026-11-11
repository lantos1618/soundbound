import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import worker, {AppleAuthBroker, handleAppleAuth, verifyAppleIdentityToken, createAppleClientSecret} from './apple-auth.mjs';
globalThis.crypto ??= webcrypto;
const now = 1_800_000_000_000;
const b64 = value => Buffer.from(value).toString('base64url');
const hash = async value => b64(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
const encode = value => b64(JSON.stringify(value));
const rsa = await crypto.subtle.generateKey({name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1,0,1]), hash: 'SHA-256'}, true, ['sign','verify']);
const jwk = {...await crypto.subtle.exportKey('jwk', rsa.publicKey), kid: 'test-key', alg: 'RS256'};
const ec = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'}, true, ['sign','verify']);
const privatePEM = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(await crypto.subtle.exportKey('pkcs8', ec.privateKey)).toString('base64')}\n-----END PRIVATE KEY-----`;
const env = {APPLE_SERVICE_ID:'app.soundbound.web', APPLE_TEAM_ID:'TEAM', APPLE_KEY_ID:'KEY', APPLE_PRIVATE_KEY:privatePEM,
  APPLE_AUTH_CALLBACK_URL:'https://auth.example.com/apple/callback'};
async function jwt(overrides = {}, headerOverrides = {}) {
  const header = encode({alg:'RS256',kid:'test-key',...headerOverrides});
  const body = encode({iss:'https://appleid.apple.com',aud:env.APPLE_SERVICE_ID,sub:'apple-user',nonce:'test-nonce',iat:now/1000,exp:now/1000+3600,email:'test@example.com',email_verified:true,...overrides});
  const signature = b64(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', rsa.privateKey, new TextEncoder().encode(`${header}.${body}`)));
  return `${header}.${body}.${signature}`;
}
const keyFetch = async () => Response.json({keys:[jwk]});
class MemoryStorage {
  values = new Map();
  queue = Promise.resolve();
  async get(key) { return this.values.get(key); }
  async put(key,value) { this.values.set(key, structuredClone(value)); }
  async delete(key) { this.values.delete(key); }
  async transaction(action) {
    const operation = this.queue.then(() => action(this));
    this.queue = operation.catch(() => {});
    return operation;
  }
}

test('validates Apple signature, issuer, audience, expiry and nonce', async () => {
  const valid = await jwt();
  assert.equal((await verifyAppleIdentityToken(valid,{audience:env.APPLE_SERVICE_ID,nonce:'test-nonce',now},keyFetch)).sub,'apple-user');
  for (const overrides of [{iss:'https://evil.example'},{aud:'another-app'},{nonce:'wrong'},{exp:now/1000-1}]) {
    await assert.rejects(verifyAppleIdentityToken(await jwt(overrides),{audience:env.APPLE_SERVICE_ID,nonce:'test-nonce',now},keyFetch));
  }
  await assert.rejects(verifyAppleIdentityToken(await jwt({}, {alg:'none'}),{audience:env.APPLE_SERVICE_ID,nonce:'test-nonce',now},keyFetch));
  const parts=valid.split('.'); parts[1]=encode({sub:'attacker'});
  await assert.rejects(verifyAppleIdentityToken(parts.join('.'),{audience:env.APPLE_SERVICE_ID,nonce:'test-nonce',now},keyFetch));
});
test('creates a five-minute ES256 Apple client secret without exposing key', async () => {
  const secret=await createAppleClientSecret(env,now);
  const [header,payload,signature]=secret.split('.');
  const claims=JSON.parse(Buffer.from(payload,'base64url'));
  assert.equal(claims.exp-claims.iat,300);
  assert.equal(claims.sub,env.APPLE_SERVICE_ID);
  assert.equal(await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},ec.publicKey,Buffer.from(signature,'base64url'),new TextEncoder().encode(`${header}.${payload}`)),true);
});
test('fails closed when Services ID or server secrets are missing', async () => {
  const result=await handleAppleAuth(new Request('https://auth.example.com/apple/start'),{},new MemoryStorage(),{now});
  assert.equal(result.status,503);
});
test('complete flow binds callback state and atomically redeems only with PKCE', async () => {
  const store=new MemoryStorage(), verifier='v'.repeat(43), challenge=await hash(verifier), clientState='s'.repeat(32);
  const start=new Request(`https://auth.example.com/apple/start?state=${clientState}&nonce=test-nonce-long-enough&code_challenge=${challenge}`);
  const first=await handleAppleAuth(start,env,store,{now});
  assert.equal(first.status,302);
  const appleURL=new URL(first.headers.get('Location'));
  assert.equal(appleURL.origin,'https://appleid.apple.com');
  assert.equal(appleURL.searchParams.get('redirect_uri'),env.APPLE_AUTH_CALLBACK_URL);
  const serverState=appleURL.searchParams.get('state');
  assert.notEqual(serverState,clientState);
  const fetcher=async url => url.endsWith('/auth/keys') ? keyFetch() : Response.json({id_token:await jwt({nonce:'test-nonce-long-enough'})});
  const callback=()=>new Request(env.APPLE_AUTH_CALLBACK_URL,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({state:serverState,code:'apple-code'})});
  const second=await handleAppleAuth(callback(),env,store,{now,fetch:fetcher});
  assert.equal(second.status,302);
  const appURL=new URL(second.headers.get('Location'));
  assert.equal(appURL.protocol,'soundbound:');
  assert.equal(appURL.searchParams.get('state'),clientState);
  const code=appURL.searchParams.get('code'); assert.ok(code);
  assert.equal((await handleAppleAuth(callback(),env,store,{now,fetch:fetcher})).status,400);
  const redeem=value=>new Request('https://auth.example.com/apple/redeem',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code,code_verifier:value})});
  assert.equal((await handleAppleAuth(redeem('x'.repeat(43)),env,store,{now})).status,401);
  const results=await Promise.all([handleAppleAuth(redeem(verifier),env,store,{now}),handleAppleAuth(redeem(verifier),env,store,{now})]);
  assert.deepEqual(results.map(x=>x.status).sort(),[200,401]);
  const profile=await results.find(x=>x.status===200).json();
  assert.equal(profile.subject,'apple-user'); assert.equal(profile.provider,'apple');
  assert.ok(!JSON.stringify(profile).includes('id_token'));
});
test('unknown state cannot reach token exchange', async () => {
  let fetched=false;
  const request=new Request(env.APPLE_AUTH_CALLBACK_URL,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({state:'x'.repeat(43),code:'stolen-code'})});
  assert.equal((await handleAppleAuth(request,env,new MemoryStorage(),{now,fetch:()=>{fetched=true;}})).status,400);
  assert.equal(fetched,false);
});

test('unknown routes never invoke the Durable Object', async () => {
  let invoked=false;
  const binding={idFromName(){invoked=true;},get(){throw new Error('must not run');}};
  const result=await worker.fetch(new Request('https://auth.example.com/unexpected'),{APPLE_AUTH:binding});
  assert.equal(result.status,404);
  assert.equal(invoked,false);
});
test('the global flow allowance stops new authorization redirects', async () => {
  const store=new MemoryStorage();
  await store.put(`limit:${Math.floor(now/86400000)}`,{count:1000,expires:now+86400000});
  const request=new Request(`https://auth.example.com/apple/start?state=${'s'.repeat(32)}&nonce=${'n'.repeat(32)}&code_challenge=${'c'.repeat(43)}`);
  const result=await handleAppleAuth(request,env,store,{now});
  assert.equal(result.status,429);
});
test('incoming requests do not postpone an existing cleanup alarm', async () => {
  const store=new MemoryStorage();
  let alarm=null,scheduled=0;
  store.getAlarm=async()=>alarm;
  store.setAlarm=async value=>{alarm=value;scheduled++;};
  const broker=new AppleAuthBroker({storage:store},{});
  await broker.fetch(new Request('https://auth.example.com/apple/health'));
  const first=alarm;
  await broker.fetch(new Request('https://auth.example.com/apple/health'));
  assert.equal(scheduled,1);
  assert.equal(alarm,first);
});
