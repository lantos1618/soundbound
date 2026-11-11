# Research note: signed peer discovery and invertible Bloom lookup tables

Status: future research, not an implemented Soundbound feature. This is an optimization to revisit after basic authorized audio streaming works.

## Paper

Michael T. Goodrich and Michael Mitzenmacher, **Invertible Bloom Lookup Tables**.

- Paper: https://arxiv.org/abs/1101.2245
- Referenced version: https://arxiv.org/abs/1101.2245v3
- DOI: https://doi.org/10.48550/arXiv.1101.2245

The paper describes a compact structure for insertion, deletion, and lookup of key-value pairs, with probabilistic recovery of all entries when the table is below its designed decoding threshold. It can contain more entries during ordinary operation; listing then becomes unreliable and lookup success can decrease. Removing enough entries can restore the useful decoding behavior. The paper also explores variants that tolerate certain erroneous deletions or conflicting insertions.

The distinctive feature is recoverability: a standard Bloom filter answers approximate membership queries, while an IBLT can also list entries under suitable conditions.

## Why this may matter for Soundbound

Two already-authorized peers might have mostly the same signed directory of devices, room membership records, or permission updates. Instead of repeatedly transferring the complete directory, they could exchange compact reconciliation tables and recover a small set of differences.

An application idea, not a result demonstrated for Soundbound:

1. Assign each signed record a stable content identifier derived from its canonical bytes.
2. Build compatible IBLTs over those record identifiers, using agreed parameters and independent local sets.
3. Exchange tables only with authorized peers in the relevant room or discovery scope.
4. Subtract corresponding tables and attempt to decode the differing identifiers.
5. Fetch the missing signed records.
6. Validate signatures, issuer authority, audience, expiry, ordering, and revocations before changing any access decision.
7. If decoding fails, negotiate a larger bounded table or fall back to paginated exact reconciliation.

Small differences between two large sets can produce a small decodable difference even when listing either original set would not succeed. This depends on table design and actual difference size, and needs benchmarks.

## Identity and signatures remain separate

The poison-bottle puzzle illustrates binary coding: ten independent yes/no outcomes distinguish up to 2^10 = 1,024 possibilities, assuming exactly one poisoned bottle and reliable outcomes. It is an analogy for compact information, not an authentication protocol or an IBLT implementation.

For Soundbound:

- A cryptographic key pair identifies a device.
- A public-key-derived identifier names that device.
- Signed challenges and announcements prove control of the corresponding private key.
- Signed, scoped grants authorize room membership and specific audio operations.
- An IBLT helps peers discover which records differ.
- An authenticated encrypted media transport carries the audio.

A table match or successfully decoded identifier never grants access by itself. Hashing an email address or an Apple login identifier does not prove identity and is not an adequate privacy measure against guessing.

## libp2p as an architecture candidate

libp2p already has public-key-derived peer identities and authenticated peer connections. It is a candidate for the identity/discovery layer, not a selected dependency or a working Soundbound integration.

References:

- Peer IDs: https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md
- Identity and authorization considerations: https://libp2p.io/docs/security-considerations/

Evaluate native iOS/macOS support, background operation, transport interoperability, dependency footprint, and interoperability with the chosen audio transport before adopting it. Identity/discovery and real-time media do not have to use the same library.

## Boundaries and failure cases

- Do not broadcast a global list of users, friends, or room memberships. Scope summaries to peers entitled to discover those records.
- Bloom-style summaries are not encryption; guessing attacks and membership leakage still need a threat model.
- No arbitrary peer may submit unbounded tables, trigger unlimited record fetches, or inject unverified grants.
- Agree hash functions, table size, record encoding, and protocol version before reconciling.
- Handle duplicate identifiers, conflicting signed updates, and deletion/revocation tombstones deterministically.
- Do not resurrect a revoked grant because another peer has an older record.
- Use bounded retries and an exact fallback when difference decoding fails.
- Signatures and reconciliation do not solve network reachability, TURN relay costs, offline availability, or instantaneous revocation across disconnected peers.

## Gate before implementation

First ship and test basic audio transport, explicit permissions, and exact device/room synchronization. Then measure whether directory size and update frequency justify an IBLT. Compare bytes transferred, CPU, decoding failures, churn, and recovery behavior against straightforward exact synchronization. Keep this out of the first media-transport milestone unless evidence justifies it.

## Tweet-sized summary

Michael T. Goodrich & Michael Mitzenmacher’s Invertible Bloom Lookup Tables recover entries from compact hashed summaries when not overloaded—letting peers sync small differences instead of entire datasets. https://arxiv.org/abs/1101.2245
