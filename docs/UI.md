# Soundbound interface

Native SwiftUI on macOS and iOS, with Apple Maps as the visual reference: quiet navigation, familiar system controls, rounded material panels, and readable device rows.

## Navigation

The app heading is simply “Soundbound”. Devices remain rows on the plain background, with names, state, and volume visible together. Each section has its own Add button.

- **Home:** devices first, then rooms, then friends and pairing requests. No sidebar.
- **Settings:** a toolbar button.

The Mac menu-bar panel puts headphone destinations and move status first, then application volumes for the current Mac, then incoming requests. Paired headphones remain selectable when disconnected; losing their active audio profile must not hide the connection controls. Mac and paired-device destination rows remain visible. A room selector can replace direct routing, with an Off option to return to device selection.

Incoming requests include headphone moves, pairing or room joining, microphone recording, and playback when approval is required. Approving a headphone move does not mark it connected: a matching observation from the target is required.

Settings shows one Sign in with Apple button when signed out, or Sign out when signed in. There is no advanced account menu. Signing out clears the app session and makes sign-in available again; Apple still controls which accounts its native sheet offers.

## Home interactions

Each room is a drop zone. Drag the device name into a room to add it; a device may belong to multiple rooms. Dragging its name leaves the volume slider independently usable. Each room has a dashed drop area and highlights while the drag is over it. Friends is a plain section and is never a drop target. A context menu provides the same actions without dragging.

A device inside a room shows its name, owner, and saved playback slider. The slider stacks below the name on narrow screens.

The local computer and its audio devices can be assigned to rooms. Paired devices are listed but remote movement requires an approved network control protocol. Audio-device sliders control real hardware output volume when macOS exposes it. Dragging does not grant microphone access or enable sharing.

## Startup

The window opens without waiting for Keychain. When macOS requires permission to read the saved signing key, the interface shows a short unlock message. Pairing and room movement wait for the existing identity; the app never silently substitutes a new identity.

## Verification

The macOS app and iOS simulator target compile. The local move, move-back, unknown-room rejection, and pairing approval tests pass. The Mac interface and actual route updates have been checked. The iPhone development build has been installed and launched on the connected device. The native drag gesture still needs a manual end-to-end check.
