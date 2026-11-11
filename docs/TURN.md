# TURN and spending protection

## Current state

Soundbound uses direct, encrypted local audio. It does not use Cloudflare TURN yet.

On November 11, 2026, the Cloudflare dashboard showed an active Realtime subscription, no TURN Server apps, and $0.00 of observed billable usage. The account already had an automatically created $10 budget **alert**. No key was created and no billing setting was changed during this check.

The credential issuer stays disabled:

- `TURN_ENABLED=false` by default; requests cannot generate relay credentials.
- The Wrangler configuration does not publish a `workers.dev` endpoint.
- No TURN key or API token belongs in the app or repository.
- If issuance is explicitly enabled later, credentials last 60 seconds, require server-side bearer authentication, and upstream requests time out after five seconds.
- Authentication errors and upstream responses do not disclose the API token. The health endpoint reports whether issuance is enabled.

These safeguards have been tested. They are **not a dollar spending cap**.

## Why the alert is insufficient

Cloudflare's documented budget alerts are notifications based on usage trends. The dashboard did not expose an account-wide hard cutoff for Realtime TURN. Its documented packet/data-rate limits apply per TURN allocation, not across the account. The included 1,000 GB is an allowance; traffic beyond it is billed at $0.05/GB.

A client-side bitrate limit, a credential issuance quota, or a short credential lifetime cannot prove a maximum bill: an issued credential can be abused outside the app, and an account may have concurrent allocations. Stopping new credentials also does not immediately revoke already issued credentials. A usage-polling kill switch can overshoot while usage data is delayed.

## Enablement requirement

Do not enable the issuer merely because Realtime has been activated. Before using a paid relay, establish an enforceable limit on the billable data path or a provider-supported hard spending cap. If Cloudflare cannot supply that guarantee, keep local/direct audio available and use a relay whose traffic can be cut off at the configured quota. Any acceptable implementation must include server-side authorization, short-lived credentials, revocation, and a fail-closed budget gate; a monitoring alert is supplemental.

## References

- [Cloudflare TURN FAQ: pricing and credential expiry](https://developers.cloudflare.com/realtime/turn/faq/)
- [TURN per-allocation limits](https://developers.cloudflare.com/realtime/turn/)
- [Generating and revoking short-lived credentials](https://developers.cloudflare.com/realtime/turn/generate-credentials/)
- [TURN analytics and sampling](https://developers.cloudflare.com/realtime/turn/analytics/)
