# First audio transport

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

Paired devices automatically accept playback by default; Settings can restore per-request approval. Unpaired identities cannot send audio. Pairing does not activate a microphone. Local input icons record only while held, stop on release/cancellation or after 30 seconds, and keep the clip in memory. Red input indicators follow measured PCM level; green indicators mark actual test transmission/playback start. The room test remains a sequence of one-to-one streams, not a many-source mixer.
