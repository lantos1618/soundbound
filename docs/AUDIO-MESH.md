# First audio transport

## Connection recovery state machine

Discovery, desired room routes, signed session negotiation, and the media channel
are separate layers. A discovered address is not an authenticated media session.

| Layer/state | Transition and guard |
| --- | --- |
| Desired room output | Requires current pairing, room membership, an available output, and local discovery. |
| Offer/reply | Fresh offer ID and ephemeral X25519 key; signed reply must match the session, participants, trusted key, and expiry. |
| TCP connecting | Bounded to eight seconds. A waiting connection may resume on an OS network-path change within that window. |
| Authenticating | TCP readiness begins a separate eight-second window for the encrypted hello; no PCM is sent before authentication. |
| Streaming | Directional session-bound encryption and replay checks; no authenticated traffic for five seconds closes the channel. |
| Closed/retry | Room application audio retains the explicit sharing intent. A failed output schedules reconciliation after five seconds, even without another discovery event. Each attempt uses a new session and keys. |
| Explicit stop/revocation | Cancels scheduled retries. Each retry rechecks current room, pairing, discovery, and output eligibility. Microphone capture still stops when its last receiver disappears. |

This applies to both macOS and iOS. It does not provide internet handoff: Bonjour
and local TCP cannot reach a home device from cellular. Signaling, ICE/STUN,
TURN transport, and background wake/recovery are still missing. A physical test
should separately check Wi-Fi loss, return to Wi-Fi, and eventual cellular relay
handoff; only local recovery is implemented here.

## Room broadcast extension

Version 4 audio offers add a signed room ID, source ID, and explicit destination output. An active emitter fans out the same PCM to independent encrypted sessions for each online, paired room output. Receivers require the same active room, source and output membership, and a paired signing identity. Room changes, removal, and Stop tear down affected routes; received audio is never republished. Each receiver permits at most 16 simultaneous room sessions. Playback is concurrent, not sample-synchronized, and there is no group-wide clipping limiter yet.

Paired devices answer signed `peer-ping` requests with a request-bound `peer-pong`. The sender measures elapsed time with a monotonic clock, probes every five seconds, and times out after two seconds. This is application round-trip latency, including TCP setup and signature processing, not one-way latency or capture-to-speaker delay.

During an audio session, encrypted heartbeat packets carry an optional echo ID and measure RTT over the already-open socket once per second. The UI labels this **Ping**, and labels the idle fresh-connection measurement **Probe**. The echo fields are optional so older peers can continue accepting heartbeat packets; they simply do not provide the persistent-connection measurement. Echoes are not echoed again, and results expire after five seconds.

The live path now uses at most 20 ms of PCM per outgoing frame, an 80 ms playback queue ceiling, and a smaller 8 KiB pending-send budget. iOS requests a 10 ms I/O buffer, which the operating system may adjust. These bounds reduce avoidable queue buildup but do not guarantee synchronized video or compensate for Bluetooth latency.

Media TCP sockets disable Nagle batching (`noDelay`) and ACK stretching so short real-time frames are not deliberately held for aggregation. Control-channel probes keep their separate timing semantics.

Mac application audio uses an explicitly started Core Audio process tap on macOS 14.2+. Microphone sharing remains explicit and waits for an authenticated receiver before capture. Test tones can also be broadcast. These new multi-output and application-capture paths need live device verification; the older single-peer behavior described below remains supported.

Implemented: one approved source sends live microphone audio (or a short test tone) to one paired receiver on the local network, with Apple peer-to-peer link discovery also enabled. This is the first mesh transport, not yet peer forwarding, internet traversal, or multi-speaker mixing.

## Protocol

- Devices pair through the existing signed invitations.
- Source advertises a temporary TCP media listener and sends a signed, short-lived audio offer through the control channel.
- Only an already-paired, locally discoverable device can trigger a playback approval prompt.
- Receiver explicitly allows playback and returns a signed ephemeral X25519 key.
- Both sides derive separate directional AES-256-GCM keys with HKDF-SHA256, bound to the session and the two device identities.
- The receiver proves it has the session key with an encrypted hello before microphone capture starts.
- Audio is PCM16, mono, 24 kHz. Frames are bounded and authenticated, with monotonic sequence checks. Replayed, tampered, cross-session, or reflected packets are rejected.
- Bounded send/playback queues drop audio under congestion rather than growing indefinitely. Heartbeats stop a session when its peer disappears.
- Either side can stop. Stopping discovery also ends the stream. iOS interruptions stop the session.

Microphone access is requested only for Share microphone. Send test tone uses no microphone. The receiver does not open a microphone to play audio.

## Test on Mac and iPhone

1. Put both devices on the same Wi-Fi and open Soundbound.
2. Use Add → Friend or device, enable Discover on both, and approve pairing.
3. In Live audio, choose the paired device and Send test tone.
4. On the receiver, choose Allow audio. A quiet one-second tone should play through its current output.
5. Choose Share microphone for continuous audio; grant microphone permission on the source and playback approval on the receiver.
6. Use Stop on either device to end the session. Use headphones to avoid acoustic feedback.

## Verification and remaining work

Automated tests cover encryption/key agreement, tamper/replay/wrong-session rejection, unpaired-sender rejection, explicit playback consent, and an actual encrypted loopback socket carrying PCM bytes.

Physical Mac-to-iPhone audibility must be verified separately. No claim of completed hardware testing is implied by the loopback test.

Not yet implemented: STUN/ICE, TURN client transport, internet signaling, mesh forwarding, Opus compression, system-audio capture, echo cancellation, or synchronized multi-speaker playback. The Cloudflare credential issuer remains separate and needs an activated TURN account plus a WebRTC/ICE media transport before it can relay this stream.

## Output tests

Tapping an output icon requests a test for that specific endpoint. Room tests visit available outputs sequentially; they are not synchronized playback. Targeted offers use protocol version 2 so older receivers cannot silently ignore the output selection. The receiver validates the endpoint before asking for approval. A Mac opens that Core Audio output directly; iOS rejects a target that is not its current output instead of choosing a different destination.

## iPhone request visibility

Incoming audio requests use a modal approval prompt. The sender keeps a visible outcome when the receiver declines, cannot start playback, or times out. iPhone notification permission supports request notifications while the process is alive, plus a bounded background grace period to respond. Active audio uses the audio background mode. This does not keep an idle app alive indefinitely and does not wake a suspended app: APNs signaling is not implemented yet.

## Trusted playback and input checks

Paired devices automatically accept playback. Unpaired identities cannot send audio. Pairing does not activate a microphone. Tap a local input icon to start recording and tap again to stop; recording also stops after 30 seconds and keeps the clip in memory. Remote microphone requests still require approval at the source. Red input indicators follow measured PCM level; green indicators mark actual test transmission/playback start. The room test remains a sequence of one-to-one streams, not a many-source mixer.
