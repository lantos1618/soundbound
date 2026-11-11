# Apple sign-in

Soundbound has two distinct sign-in paths:

- **Sign in with Apple** uses the device’s native Apple authorization sheet. It is tied to the Apple Account available to the OS.
- **Use another Apple Account** opens an ephemeral web authorization session. It does not sign the Mac out of iCloud or change its Apple Account.

Signing out cancels pending authorization, clears Soundbound’s cached profile, and invalidates outstanding credential checks. A late check cannot sign the app back in.

## Current setup

Native iOS and macOS development builds have the Sign in with Apple entitlement and provisioning profiles. The alternate-account path requires a deployed broker and a registered Services ID before its button is enabled. Do not claim account switching is available merely because the client code compiles.

Set `SoundboundAppleWebAuthURL` in each app’s Info.plist to the broker’s HTTPS `/apple/start` URL only after the service is configured. No Apple private key belongs in the app.

## Broker configuration

`server/apple-auth.mjs` is a separate Worker/Durable Object module. It does not enable or issue TURN credentials. Its dedicated configuration is `server/wrangler.apple-auth.jsonc`, using a SQLite-backed Durable Object supported by the Workers Free plan.

Keep the account on **Workers Free**. Do not upgrade to Workers Paid for this prototype. Free-plan daily request and storage operation limits cause requests to fail when exhausted; the app's 1,000-flow limit is additional abuse resistance, not a substitute for that account-level free-plan restriction.

Deployment requires the already-registered Services ID and exact callback to match the config. Store `APPLE_PRIVATE_KEY` and `APPLE_KEY_ID` as Worker secrets, deploy with the dedicated configuration, then verify `/apple/health` reports `configured: true` before enabling the client URL. Never copy either secret into a plist or source file.

Required bindings and secrets:

- `APPLE_AUTH`: Durable Object namespace for `AppleAuthBroker`.
- `APPLE_SERVICE_ID`: Apple Services ID, grouped with the intended primary App ID.
- `APPLE_TEAM_ID` and `APPLE_KEY_ID`.
- `APPLE_PRIVATE_KEY`: Sign in with Apple `.p8` key, stored only as a Worker secret.
- `APPLE_AUTH_CALLBACK_URL`: exact registered HTTPS URL ending in `/apple/callback`.

Register the HTTPS domain and callback with the Services ID in Apple Developer. Group native App IDs and Services ID deliberately if they must share Apple subject identifiers; equal display names or email addresses are not account identity proof.

## Verification and session behavior

The app supplies fresh state, nonce, and a PKCE challenge. The broker stores expiring flow state, exchanges the Apple authorization code, verifies Apple’s RS256 signature against Apple’s public keys, and checks issuer, audience, nonce, expiration, and issue time. It then returns a 60-second one-use redemption code. Atomic Durable Object storage prevents double redemption. The app redeems that code with its PKCE verifier over HTTPS.

Apple identity/access/refresh tokens are not persisted or returned to the app. The app retains the verified web profile only for the current run, for at most one hour. After relaunch, web sign-in must be repeated. Cached display metadata does not count as authentication. Native credential-state checks do not override web-account selection.

This broker verifies sign-in; it does not yet create account-level room grants or a public friend directory. Those require server-enforced authorization. Native sign-in by itself must not transfer room ownership.

The broker caps new flows at 1,000/day for this prototype and expires state. That is an availability/abuse control, not a Cloudflare billing cap. Hosting needs its own deployment and cost review.

## Tests

`server/apple-auth.test.mjs` covers signature and claim validation, ES256 client-secret generation, disabled configuration, state/PKCE binding, atomic one-use redemption, callback replay, and rejection before an unrecognized state can contact Apple.

## Public endpoint bounds

Only four exact routes are accepted. Unknown paths and oversized declared bodies are rejected before reaching the Durable Object. Read bodies are capped at 16 KiB even without a Content-Length header. The server creates at most 1,000 authorization flows per UTC day, expires flow state after ten minutes and redemption codes after one minute, and removes expired records using an alarm that incoming traffic cannot keep postponing. Replays and invalid state cannot trigger an Apple token exchange. These controls can make abusive traffic fail; on a paid hosting plan they do not impose a dollar ceiling.
