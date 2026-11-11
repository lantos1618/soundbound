# Soundbound

A native macOS and iOS app for managing audio devices and sharing sound with permission.

**Status:** early development. Local device controls, pairing, and one-way encrypted audio are implemented. A Mac-to-iPhone test tone has been heard on the receiving device. Continuous microphone streaming still needs broader device and network testing.

## What works

- Discover local inputs, outputs, Bluetooth headphones, and nearby Soundbound devices.
- Use the menu-bar panel for headphone destination, pending requests, and this Mac’s app volumes. Manage rooms in the main app. System Audio Recording permission is required for application mixing on macOS 14.2+.
- Keep devices in several rooms and activate one room at a time on each host; turning a room off keeps its membership. Room activation does not yet create a synchronized multi-device mix.
- Select the Mac’s output or microphone and adjust supported hardware volume.
- Pair devices using a compact nearby QR code card, an inline iPhone camera scanner, short codes, nearby discovery, and explicit approval.
- Sign in with Apple in signed builds. Native sign-in works with the device’s Apple Account. The separate web sign-in flow is deployed but still being validated on devices. Account-wide friends and room permissions are not connected yet.
- Reconciled device inventories and separate [observed/requested device states](docs/DEVICE-STATE.md), without treating a requested connection as confirmed.
- Send a short test tone or share a microphone with one paired receiver.
- Stop audio from either device. Pairing grants playback permission, without another approval for each sound. Unpaired devices cannot send audio. Sharing a microphone still requires microphone permission and an explicit source action.
- Organize local and paired devices into rooms. Local and paired devices can belong to multiple rooms. Inputs and outputs sit beneath their host device. Adding the host includes its attached components; individual components can also be added separately. Room definitions and layouts mirror from their creating device to nearby paired devices; edits stay on the creating device. Membership does not grant audio access.
- Distinguish built-in, Bluetooth, Apple Continuity, wired, and virtual endpoints. Drag wireless headphones onto a host to request a move; built-in hardware stays attached. iPhone uses Apple’s output chooser after approval.
- Configure per-device change confirmations, notifications, and removal after a sustained disconnect.
- Tap a device icon for a short test tone; green shows playback, amber shows a pending request. Tap a local microphone to record; tap again to stop. A red amplitude waveform shows captured audio.
- Tap a device’s output icon to keep its test sound playing; tap again to stop. Tap a room name to test its available outputs briefly in sequence. Paired devices play automatically.

Both apps use the version and build number in `VERSION`, shown at the bottom of Settings.
Run `bash scripts/build-both.sh` to build the same source for both platforms and verify both bundles match `VERSION`. A mismatched pair fails the build check. UI, device state, pairing, room logic, and the audio transport live in the shared `SoundboundKit` package; platform adapters handle macOS Core Audio and iOS audio sessions.

Right-click a room heading or open its gear menu to delete a room. Deletion keeps paired devices intact.

Drag device names to add them to rooms; right-click on Mac or long-press on iPhone for settings. Remote microphone recording sends a signed request to the source device for approval, then returns encrypted audio into memory on the requesting device. This new path still needs a live two-device test.

Apple’s automatic AirPods handoff cannot be intercepted. Set **Connect to This Mac/iPhone → When Last Connected** on both devices to stop Apple switching them automatically. Soundbound can approve its own move requests, not Apple’s system handoffs.

## Try audio sharing

1. Open Soundbound on both devices and enable Discover. A shared Wi-Fi network is the simplest setup; Apple peer-to-peer discovery is also enabled.
2. Tap **+** beside **Devices**, send a pairing request, and approve it on the other device. Compare the device fingerprint when pairing.
3. Tap an output device’s icon to send a short test tone, or tap a room name to test the room in sequence.
4. Paired receivers play automatically by default. Tap a local microphone to record; tap again to stop. Recordings stay in memory on that device.

Use headphones to avoid acoustic feedback. This build shares one source with one receiver; it does not yet mix multiple sources or synchronize speakers.

## Encryption and trust

Audio is encrypted directly between the source and receiver:

- Persistent Ed25519 device keys sign the audio offer and acceptance.
- Each session uses fresh X25519 key agreement.
- HKDF-SHA256 derives separate 256-bit keys for each direction, bound to the session and both device identities.
- AES-256-GCM encrypts and authenticates packets. Sequence checks reject replay within the connection.
- The receiver proves possession of its session key before the source starts capturing a microphone.

Discovery, pairing, and paired-device inventory metadata—including device names, attached audio devices, public keys, and shared room layouts—is **not encrypted**. Nearby names are not proof of identity; verify fingerprints before trusting a device. Traffic timing and size remain visible. Audio is decrypted in device memory for playback.

This is a custom prototype protocol built with Apple CryptoKit, **not an independently audited secure transport**. Do not treat it as production-grade security for sensitive audio. See the [security design and diagrams](docs/SECURITY.md) for trust boundaries and remaining work.

## Build

Requires Xcode and macOS 13+ or iOS 16+.

```sh
bash scripts/build.sh
open dist/Soundbound.app
```

For iPhone, open `Apps/iOS/Soundbound.xcodeproj`, choose your development team and device, and run.

Development builds keep their device signing identity in a local, owner-only JSON file outside the repository. Release builds use Keychain. Native Apple login requires the provisioned Xcode build; no app-specific password is needed. See [development setup](docs/DEVELOPMENT.md).

```sh
swift test --disable-sandbox --build-system native
```

Tests cover routing verification, pairing consent, identity storage, encryption, replay/tamper rejection, and encrypted loopback transport. Hardware audibility is tested separately.

## Not implemented yet

Account-based friendships, account-wide room authorization, APNs wake-up delivery; internet signaling, STUN/ICE and TURN client transport; mesh forwarding, system-audio capture, Opus compression, and multi-speaker synchronization. Cloudflare Realtime is activated, but no TURN key or deployed issuer is configured. Credential issuance is disabled by default because an enforceable account spending cap has not been established. The current audio path remains local. See [TURN cost controls](docs/TURN.md).

Soundbound cannot prevent Apple’s automatic AirPods switching or remotely reassign another app’s iPhone audio session.

[Audio protocol](docs/AUDIO-MESH.md) · [Device model](docs/DEVICE-MODEL.md) · [Local controls](docs/LOCAL-AUDIO.md)

Right-click a room on Mac or long-press it on iPhone to delete it. Deleting a room removes its grouping, not the paired devices.
