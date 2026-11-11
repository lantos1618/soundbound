# Local audio controls

The Mac build now discovers Core Audio inputs and outputs, plus paired Bluetooth audio devices. Home contains devices, rooms, and friends. There is no sidebar.

## What works

- Select a Mac output or default microphone from a device’s menu.
- Change output hardware volume when the device exposes a writable volume control. A missing control is not replaced with a fake software slider.
- Connect a paired Bluetooth headset to this Mac, or disconnect it. Selecting an output is not reported as proof that audio has audibly switched.
- Run a quiet headphone test and explicitly confirm whether it was heard.
- Assign a local audio endpoint to a room by dragging it or using its menu. Assignments in owner-created rooms are mirrored to nearby paired devices. Bluetooth input and output endpoints share a stable identity when the paired hardware can be identified.
- Show the iPhone’s current audio route without starting microphone capture or changing other apps’ audio sessions.

Room membership currently organizes devices. It does not stream or mix audio between computers and phones. Moving a microphone into a room does not start recording or grant capture permission.

## Verification

`VerifiedAudioRouting` checks availability, requests the change, and polls the actual default device or volume. A successful Core Audio write alone is not success. A disappeared device, rejected write, unconfirmed change, or unsupported hardware volume returns an error. The UI’s route labels come from the actual hardware state.

Tests cover delayed acknowledgment, successful writes that never take effect, disappearing hardware, rejected operations, bounded volume values, unsupported volume, and persisted room assignment.

Bluetooth connection and disconnection are bounded attempts; they cannot guarantee an Apple automatic-switching takeover. An iPhone cannot have another app’s global audio session reassigned by Soundbound. Cross-device transport remains separate work.

## Build and install on an iPhone

Open `Apps/iOS/Soundbound.xcodeproj`, select a connected iPhone and an Apple developer team, and run. Development builds use a local identity file; production uses Keychain. No account is required for local pairing. Discover is opt-in, and pairing requires the other device’s approval. Camera permission is requested only when scanning a QR code.

Developer installation can also use `xcodebuild` for a specific device and `xcrun devicectl device install app`. Build products and signing assets are not source files and should not be published.

Apple reference: [AudioObjectSetPropertyData](https://developer.apple.com/documentation/coreaudio/audioobjectsetpropertydata(_:_:_:_:_:_:)) explicitly documents that property changes can complete asynchronously.

## Per-device settings

Each audio device has a gear button. It opens routing actions, room membership, and three saved policies:

- Ask before Soundbound changes the connection or default route (enabled initially).
- Tell me when the device connection or selected route changes (enabled initially).
- Remove the device from its room after a sustained disconnect (off initially; three-second grace period).

The confirmation applies to changes initiated by Soundbound. It cannot intercept Apple’s automatic switching. Route notifications report an observed change afterward. When the Mac window is active, notifications appear within the app; otherwise they use a brief, nonactivating panel.

The Mac app includes a standard application menu with Quit Soundbound (Command-Q), plus editing and window shortcuts.

The main screen no longer includes a standalone Live audio panel. Use a room’s Test sound action for audio checks and microphone sharing. Pending playback requests and active-session Stop remain visible on Home.
