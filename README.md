# Soundbound

A native macOS and iOS app for managing audio devices and sharing sound with permission.

**Status:** early development. Local device controls, pairing, encrypted audio, and room broadcast routing are implemented. Mac application audio has been heard on a receiving iPhone during a live YouTube test. Playback across multiple simultaneous physical outputs still needs a listening test; the user reported a small video/audio delay.

## What works

- Discover local inputs, outputs, Bluetooth headphones, and nearby Soundbound devices.
- See live round-trip ping on active encrypted audio connections, refreshed every second. When idle, **Probe** measures a new connection and signed response every five seconds. Neither is an estimate of total audio/video delay. Offline and stale results are not shown as live measurements.
- The connection label shows local TCP and the interface actually selected by Network.framework, such as Wi-Fi or Ethernet. It uses the active audio path when streaming and the ping connection otherwise. Bonjour is shown separately as discovery. Bluetooth remains a local headphone connection; STUN, TURN, and WebRTC are not active transports in this build.
- Active network RTT is displayed to one decimal place. **Speaker delay: not measured** is an explicit placeholder, not a failed network measurement. The label **Network RTT** is network round-trip time, not capture-to-speaker delay. A separate acoustic check on the connected Mac and iPhone measured about 29 ms of additional iPhone-speaker delay relative to the Mac speaker (two matching chirps, local Ethernet-class path). That is a result for that device setup, not a guaranteed or continuously measured latency.
- Live receivers now render continuously from a bounded jitter buffer, initially reserving 10 ms of audio and increasing to at most 60 ms after starvation and gradually lowering the target after stable delivery, while retaining headroom for observed packet gaps and the render quantum. Gradual resampling compensates for sender/receiver clock drift; 5 ms fades soften startup, starvation, and backlog recovery. This trades some latency for smoothness and does not synchronize different outputs. PCM packets now carry at most 1 ms (48 bytes at 24 kHz mono PCM16), and capture/session buffers request a 1 ms cadence where the OS permits it. Splitting larger capture callbacks does not remove their capture delay. The earlier 29 ms acoustic result predates this buffer and must be measured again for this build.
- Use the menu-bar panel for headphone destination, pending requests, and this Mac’s app volumes. Manage rooms in the main app. System Audio Recording permission is required for application mixing on macOS 14.2+.
- Keep devices in several rooms and activate one room at a time on each host; turning a room off keeps its membership. Room activation does not yet create a synchronized multi-device mix.
- Select the Mac’s output or microphone and adjust supported hardware volume.
- Every audio endpoint has a Soundbound playback or microphone-gain slider, including virtual and disconnected devices. These gains are saved separately for input and output and applied to Soundbound audio; **Device volume** controls hardware only when the OS exposes it. Remote **Send level** controls this sender's audio and **Recording** controls locally received microphone recordings, not the remote device's system settings.
- Pair devices using a compact nearby QR code card, an inline iPhone camera scanner, short codes, nearby discovery, and explicit approval.
- Sign in with Apple in signed builds. Devices signed in to the same Apple Account connect automatically on the local network, without codes or pairing approval. Discovery starts after sign-in unless explicitly disabled. Other people's devices still require manual pairing. Web sign-in supports this after deployment of the updated auth broker and a fresh sign-in; it still needs validation on physical devices. There is no cloud device directory or internet audio transport.
- Reconciled device inventories and separate [observed/requested device states](docs/DEVICE-STATE.md), without treating a requested connection as confirmed.
- Send a short test tone or share a microphone with one paired receiver.
- Broadcast Mac application audio, an explicitly enabled microphone, or a test tone to a room's online paired outputs. Each receiver must have that same room active. Each output gets an independent encrypted connection; speakers are not synchronized.
- Stop audio from either device. Pairing grants playback permission, without another approval for each sound. Unpaired devices cannot send audio. Sharing a microphone still requires microphone permission and an explicit source action.
- Organize local and paired devices into rooms. Local and paired devices can belong to multiple rooms. Inputs and outputs sit beneath their host device. Adding the host includes its attached components; individual components can also be added separately. Room definitions and layouts mirror from their creating device to nearby paired devices; edits stay on the creating device. Membership does not grant audio access.
- Distinguish built-in, Bluetooth, Apple Continuity, wired, and virtual endpoints. Drag wireless headphones onto a host to request a move; built-in hardware stays attached. iPhone uses Apple’s output chooser after approval.
- Configure per-device change confirmations, notifications, and removal after a sustained disconnect.
- Tap a device icon for a short test tone; green shows playback, amber shows a pending request. Tap a local microphone to record; tap again to stop. A red amplitude waveform shows captured audio.
- Tap a device’s output icon to keep its test sound playing; tap again to stop. In an active room, this broadcasts to the room's available outputs. Use a room’s play button to start or stop a simultaneous room test.

Both apps use the version and build number in `VERSION`, shown at the bottom of Settings.
Run `bash scripts/build-both.sh` to build the same source for both platforms and verify both bundles match `VERSION`. A mismatched pair fails the build check. UI, device state, pairing, room logic, and the audio transport live in the shared `SoundboundKit` package; platform adapters handle macOS Core Audio and iOS audio sessions.

Right-click a room or open its Room actions menu to delete it. Deletion keeps paired devices intact.

Drag device names to add them to rooms; right-click on Mac or long-press on iPhone for settings. Remote microphone recording sends a signed request to the source device for approval, then returns encrypted audio into memory on the requesting device. This new path still needs a live two-device test.

Apple’s automatic AirPods handoff cannot be intercepted. Set **Connect to This Mac/iPhone → When Last Connected** on both devices to stop Apple switching them automatically. Soundbound can approve its own move requests, not Apple’s system handoffs.

## Try audio sharing

1. Open Soundbound on both devices. A shared Wi-Fi network is the simplest setup; Apple peer-to-peer discovery is also enabled.
2. Sign in to the same Apple Account on both devices to connect automatically. If discovery was explicitly turned off, enable it in Settings. For someone else's device, tap **+** beside **Devices**, send a pairing request, and approve it on the other device. Compare the device fingerprint when pairing manually.
3. Add the hosts or individual outputs to a room. Activate that room on each participating device.
4. On the Mac, choose **Share Mac audio** in the room or menu-bar panel. System Audio Recording permission is required on macOS 14.2 or later. Press **Stop** to turn the room off on this device.
5. Tap a room name to broadcast a test tone to its available outputs. Choose **Share microphone with active room** on a microphone to broadcast it explicitly; outside an active room the microphone icon still records only into local memory.

Use headphones to avoid acoustic feedback. Room audio remains on the local network. Received audio is never forwarded into the emitter. Mac app audio already plays on its selected local output; it is also sent to other room outputs without doubling that local output. Microphones are not monitored on their own host. Independent playback streams are not synchronized or protected by a shared mixer limiter.

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

Account-based friendships, account-wide room authorization, APNs wake-up delivery; internet signaling, STUN/ICE and TURN client transport; mesh forwarding, Opus compression, and multi-speaker synchronization. Cloudflare Realtime is activated, but no TURN key or deployed issuer is configured. Credential issuance is disabled by default because an enforceable account spending cap has not been established. The current audio path remains local. See [TURN cost controls](docs/TURN.md).

Soundbound cannot prevent Apple’s automatic AirPods switching or remotely reassign another app’s iPhone audio session.

[Audio protocol](docs/AUDIO-MESH.md) · [Device model](docs/DEVICE-MODEL.md) · [Local controls](docs/LOCAL-AUDIO.md)

Right-click a room on Mac or long-press it on iPhone to delete it. Deleting a room removes its grouping, not the paired devices.

Live PCM delivery uses dedicated worker queues; UI counters and meters are coalesced to at most 30 updates per second. Mac application sharing uses one global process tap excluding Soundbound, so app starts, pauses, and exits do not recreate the capture device. Soundbound's own private aggregates are excluded from device inventory and connection notifications. The application capture lifecycle is logged under subsystem `app.soundbound`, category `capture` for diagnosis.

The private Mac application-capture aggregate requests a 128-frame hardware buffer when supported (about 2.7 ms at 48 kHz), with the actual accepted frame count recorded in the capture log. Unsupported requests keep the working device configuration. This is separate from the adaptive playback reserve and does not establish end-to-end latency.

Open a room’s context menu → 3D room / scan (on iPhone, use Room actions). Markers show device names. On iPhone, Scan with LiDAR / camera starts ARKit, using LiDAR when supported. Set a floor origin, aim at each device to place it, and mark the iPhone after setting it on its stand. Saved device positions and detected planes sync to paired room members; the AR world map stays on the scanning iPhone and camera images are not shared. Grey markers remain examples until placed. Manual edits remain local. This is placement, not continuous motion tracking, acoustic calibration, or multichannel surround rendering. Queued audio, buffer target and recovery count are shown separately; none is an acoustic end-to-end measurement.

Device audio icons use a single click/tap to mute or restore the previous Soundbound gain, and a double click/tap to start or stop output test audio. Microphone icons do not start recording through these gestures. Level meters use right-aligned vertical bars. Device context menus expose settings, gain and test actions, plus membership changes on the room owner’s device. The menu-bar popover is 380 points wide.

Settings → Developer → Show connection diagnostics reveals observed TCP endpoints, available path interfaces and the OS path description for live audio or the last idle probe. These are local diagnostics, not a traceroute. A physical Wi-Fi/Ethernet path does not prove VPN bypass: ordinary labels say TCP and keep VPN status unknown unless a tunnel interface is exposed. Background audio is enabled on iOS; active playback may continue while locked, whereas an idle/suspended or force-quit app is not an always-running receiver service.

On first discovery of an idle paired peer, Soundbound compares up to eight discovered TCP addresses with three signed probes per address. It ranks successful routes by median setup/reply time plus variability and failed-probe penalties, retains the current address for near ties, and uses the selected address for new connections without interrupting existing audio. Developer diagnostics and the paired-device context menu offer a manual retest. This is a connection probe, not an audible-latency test, and it obeys OS/VPN routing; BLE audio, WebRTC, TURN and dedicated relays are not implemented candidates. On iPhone the room menu is a vertical three-dot button.

The iPhone room scanner now uses a full-screen camera, floor-origin step and real-room-output picker. There are no generated speaker positions or extra listener/device placeholders. YOLO26 nano highlights laptops and phones on-device; tap a highlight to place the selected real output, or use the crosshair for speakers. Review THIRD_PARTY_MODELS.md for asset provenance and license. The room drop area also opens an Add device menu; an existing room member can request adding its own reported output through the paired room owner.
