# Apple sign-in

Settings presents **Sign in with Apple** when signed out and **Sign out** when signed in. It explicitly labels the signed-out state and shows progress and cancellation while authorizing. Signing out immediately makes sign-in available again.

The visible sign-in uses the device’s native Apple authorization sheet. It is tied to the Apple Account available to the OS. Signing out of Soundbound does not sign the device out of iCloud or force Apple to offer a different account.

When the web broker URL is configured, Settings also presents **Use another Apple Account**, both signed in and signed out. It opens a separate web authentication session without shared browser cookies. Cancelling or failing account selection preserves the existing Soundbound account; the account is replaced only after successful verification. The alternate-account flow still requires a real-account end-to-end device check.

Signing out cancels pending authorization, clears Soundbound’s cached profile, and invalidates outstanding credential checks. A late check cannot sign the app back in.

Web sign-in attempts time out locally after nine minutes, before the broker's ten-minute expiry. Settings shows a retry message and preserves the existing account. The deadline is checked again when the app becomes active and when Apple returns, so sleeping the Mac cannot resume an expired attempt.

## Current setup

Native iOS and macOS development builds have the Sign in with Apple entitlement and provisioning profiles. The alternate-account broker is deployed at `https://soundbound-auth.l-leong1618.workers.dev`, using Services ID `app.soundbound.web`. Both app configurations point to its `/apple/start` URL. The health check and redirect to Apple pass. A device test has reported an incomplete web sign-in; alternate-account login is not yet verified end to end.

`SoundboundAppleWebAuthURL` is set in both app Info.plists. Apple signing secrets are stored only in the auth Worker; no private key belongs in the app or repository.

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

The app rejects callbacks with the wrong state or target, duplicate state/code fields, or both a code and an error. Known failure codes produce short diagnostic messages without exposing authorization codes, tokens, or raw server errors.

Access and refresh tokens are not persisted or returned to the app. For a device-bound nonce, the broker returns the verified Apple identity assertion only in the HTTPS, one-use PKCE redemption response. It expires out of broker storage within one minute and never appears in the browser callback. The app stores it with the profile so other devices can verify the binding. The app retains authenticated web sign-in only for the current run, for at most one hour; after relaunch, web sign-in must be repeated. Cached display metadata does not count as authentication. Native credential-state checks do not override web-account selection.

This broker verifies sign-in; it does not host a cloud device or friend directory. On the local network, devices verify each other's Apple identity assertions before granting same-owner room controls. Signing in alone never takes ownership of a room on another account.

The broker caps new flows at 1,000/day for this prototype and expires state. That is an availability/abuse control, not a Cloudflare billing cap. Hosting needs its own deployment and cost review.

## Tests

`server/apple-auth.test.mjs` covers signature and claim validation, ES256 client-secret generation, disabled configuration, state/PKCE binding, atomic one-use redemption, callback replay, and rejection before an unrecognized state can contact Apple.

## Public endpoint bounds

Only four exact routes are accepted. Unknown paths and oversized declared bodies are rejected before reaching the Durable Object. Read bodies are capped at 16 KiB even without a Content-Length header. The server creates at most 1,000 authorization flows per UTC day, expires flow state after ten minutes and redemption codes after one minute, and removes expired records using an alarm that incoming traffic cannot keep postponing. Replays and invalid state cannot trigger an Apple token exchange. These controls can make abusive traffic fail; on a paid hosting plan they do not impose a dollar ceiling.

## Known broker defect (fixed in source, not yet deployed)

The deployed broker called Apple with `redirect: 'error'`, which the Workers runtime rejects before sending the request. That surfaces in the app as AUTH-EXCHANGE on every alternate-account attempt. `server/apple-auth.mjs` now uses `redirect: 'manual'`; redeploy the Worker for it to take effect.

## Linking a person's own devices

Open Soundbound on both devices and sign in to the same Apple Account. Local discovery starts automatically unless the user explicitly disabled it. Nearby devices with matching, verified Apple accounts appear under Devices without codes or approval. Settings distinguishes native and web sign-in and explains discovery status. A shared Wi-Fi network is the simplest setup. This does not import Apple's iCloud hardware list: each device must run Soundbound, and there is no cloud directory or internet transport.

Native and web sign-in set the request nonce to a value derived from this device's public key and retain Apple's signed identity token as a device-ownership assertion. A receiver checks Apple's RS256 signature against Apple's published keys, issuer, audience (one of the two native bundle IDs or the web Services ID), nonce against the sender's key, and that it was issued within 180 days. This is an ownership assertion, not a currently valid Apple access token. A fresh sign-in is needed when it gets too old or the device key changes. Apple's app identifiers must belong to the intended Sign in with Apple group; emails are never used to merge accounts.

Automatic linking uses two signed exchanges. A probe binds a pair-specific account hint to the advertised invitation nonce, sender and recipient. The hint grants no permissions. A matching receiver issues a single-use, 30-second challenge. The sender answers with its device-bound assertion; only after verifying it does the receiver add the sender and return its own assertion. The initiator independently verifies that assertion before adding the receiver. No identity token is placed in Bonjour TXT records. Different-account probes receive no assertion. Proofs in the exchange and subsequent inventories are signed but not encrypted, like the existing local metadata protocol.

Attempts are bounded and retried after 30 seconds; Apple key fetches are coalesced and temporarily backed off after failure. Replies with the wrong signer, target, challenge, account, device binding or timestamp grant nothing. Turning discovery off invalidates pending handshakes. Signing out or switching accounts removes automatically linked devices and their mirrored rooms locally, while preserving manually approved pairings. A remote sign-out removes an automatic link on its next signed inventory update. An offline device cannot receive immediate revocation. Explicitly removing an automatic device suppresses re-adding it; it can still be added manually.

Such a device may change room members, edit the room (name, place, who can find it, guests) and delete it on the device that holds it. The holder verifies the link on every request; ownership and membership never travel inside an edit. Signing out stops sending the proof and removes the link on both sides.

Room membership and edit requests carry the sender's device-bound Apple proof so the holder can verify ownership even before its next inventory refresh. Already paired devices also retry account linking when their same-account verification is missing. A verified owner's membership command may refer to its own newly connected audio component before that component appears in the holder's inventory; guest commands still require the existing role and inventory checks. Successful membership changes refresh the holder's layout immediately. A network timeout is reported as a missing response, not an owner refusing permission.

The updated broker must be deployed before web sign-in can return device assertions; old web profiles need a fresh sign-in. Native linking does not depend on that broker. Automated tests cover automatic discovery, mutual ownership, different accounts, invalid proofs, binding, replay, opt-out and revocation.

On November 12, 2026, the physical Mac and iPhone showed one another as the same Apple Account without manual pairing. Build 0.3.0 (2026111209) fixed an initial-inventory race: the iPhone's live count-only diagnostic confirmed receipt of four Mac audio devices, and the Mac displayed the iPhone speaker and microphone. This verifies local device linking and inventory exchange; web linking, first-time permission prompts and audio playback were not part of that check.
