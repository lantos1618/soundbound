# Soundbound

A native macOS and iOS app for managing audio devices and sharing sound with permission.

**Status:** early development. Local device controls, pairing, and one-way encrypted audio are implemented. A Mac-to-iPhone test tone has been heard on the receiving device. Continuous microphone streaming still needs broader device and network testing.

## What works

- Discover local inputs, outputs, Bluetooth headphones, and nearby Soundbound devices.
- Select the Mac’s output or microphone and adjust supported hardware volume.
- Pair devices using signed QR invitations, short codes, and explicit approval.
- Send a short test tone or share a microphone with one paired receiver.
- Stop audio from either device. Microphone capture starts only after permission and receiver approval.
- Organize local and paired devices into rooms. Local and paired devices can belong to multiple rooms. These assignments are local organization, not remote-control grants.
- Configure per-device change confirmations, notifications, and removal after a sustained disconnect.
- Test a room’s outputs and paired receivers, or record a three-second microphone check for local replay. Test recordings remain in memory until the panel closes.

## Try audio sharing

1. Open Soundbound on both devices and enable Discover. A shared Wi-Fi network is the simplest setup; Apple peer-to-peer discovery is also enabled.
2. Tap **+** beside **Devices**, send a pairing request, and approve it on the other device. Compare the device fingerprint when pairing.
3. In **Live audio**, select the paired device and choose **Send test tone**.
4. Approve playback on the receiver. For continuous audio, choose **Share microphone** and grant microphone access on the source.

Use headphones to avoid acoustic feedback. This build shares one source with one receiver; it does not yet mix multiple sources or synchronize speakers.

## Encryption and trust

Audio is encrypted directly between the source and receiver:

- Persistent Ed25519 device keys sign the audio offer and approval.
- Each session uses fresh X25519 key agreement.
- HKDF-SHA256 derives separate 256-bit keys for each direction, bound to the session and both device identities.
- AES-256-GCM encrypts and authenticates packets. Sequence checks reject replay within the connection.
- The receiver proves possession of its session key before the source starts capturing a microphone.

Discovery and pairing metadata—including device names and public keys—is **not encrypted**. Nearby names are not proof of identity; verify fingerprints before trusting a device. Traffic timing and size remain visible. Audio is decrypted in device memory for playback.

This is a custom prototype protocol built with Apple CryptoKit, **not an independently audited secure transport**. Do not treat it as production-grade security for sensitive audio.

## Build

Requires Xcode and macOS 13+ or iOS 16+.

```sh
bash scripts/build.sh
open dist/Soundbound.app
```

For iPhone, open `Apps/iOS/Soundbound.xcodeproj`, choose your development team and device, and run.

Development builds keep their identity in a local, owner-only JSON file outside the repository. Release builds use Keychain. See [development setup](docs/DEVELOPMENT.md).

```sh
swift test --disable-sandbox --build-system native
```

Tests cover routing verification, pairing consent, identity storage, encryption, replay/tamper rejection, and encrypted loopback transport. Hardware audibility is tested separately.

## Not implemented yet

Account-based friendships and Apple sign-in/onboarding; internet signaling, STUN/ICE and TURN client transport; mesh forwarding, system-audio capture, Opus compression, and multi-speaker synchronization. Cloudflare Realtime activation and TURN keys are not configured. The included credential-server code is preparatory and is not used by the current audio path.

Soundbound cannot prevent Apple’s automatic AirPods switching or remotely reassign another app’s iPhone audio session.

[Audio protocol](docs/AUDIO-MESH.md) · [Device model](docs/DEVICE-MODEL.md) · [Local controls](docs/LOCAL-AUDIO.md)
