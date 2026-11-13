# Soundbound interface

Native SwiftUI on macOS and iOS, with Apple Maps as the visual reference: quiet navigation, familiar system controls, rounded material panels, and readable device rows.

## Navigation

The app heading is “Soundbound” with one status line beneath it: “In <room>” for the room this device has joined, or “Not in a room”. Rooms and device hosts are cards; each section has a labelled Add button.

- **Home:** rooms first, then devices grouped by host (this device, then each paired device), then a single Friends row. No sidebar.
- **Settings:** a toolbar button.

The Mac menu-bar panel opens with the live-room status line and Share Mac audio, then any incoming requests (the section is absent when there are none), then headphone destinations and move status, then application volumes for the current Mac. Paired destinations show only “Ask to move” or “Offline”; connection diagnostics stay in the main app. Paired headphones remain selectable when disconnected; losing their active audio profile must not hide the connection controls. Mac and paired-device destination rows remain visible. Room controls live only in the main app, reached through Open Soundbound.

Incoming requests include headphone moves, pairing or room joining, microphone recording, and playback when approval is required. Approving a headphone move does not mark it connected: a matching observation from the target is required.

Settings labels the signed-out state and shows Sign in with Apple, or Sign out when signed in. Use another Apple Account opens web sign-in when configured, and remains available in either state. Progress and Cancel sign-in appear during authorization. Signing out clears the app session; Apple still controls which accounts its native sheet offers. Cancelling web account selection preserves the existing account.

## Home interactions

Each room is a drop zone. Drag the device name into a room to add it; a device may belong to multiple rooms. Dragging its name leaves the volume slider independently usable. Each room has a dashed drop area and highlights while the drag is over it. Friends is a plain section and is never a drop target. A context menu provides the same actions without dragging.

In Devices, inputs and outputs are indented beneath their host with a guide line; wireless headphones that can move between hosts can be dragged onto another host. Every device row ends in a vertical-dots menu (dimmed until the pointer is over the row on Mac) holding the same actions as its context menu, including Move to another host for headphones. Dragging them by name onto another host’s card asks that host to take them over; the whole card highlights as the drop target. Anything else dropped on a host card leaves its rooms. A paired device that is offline keeps its last reported built-in speakers and microphones listed, dimmed and marked Away, with their saved levels visible but disabled until available; headphones are not remembered because they may have moved. These remembered rows are display only and are never used for routing. A device with nothing to show says why (offline, or still waiting). Device rows with a reported input or output capability show one slider and a chevron; unavailable devices have disabled sliders. The slider is hardware volume when the OS exposes it, otherwise the Soundbound level, and it is the same control in a room and in Devices, so the two rows always agree. The chevron reveals the remaining levels and latency figures. The slider sits beside the name when the window is at least 680 points wide and on its own line below when narrower; the rule is the window’s width, not the platform, so a narrow Mac window and an iPhone show the same row. On narrow layouts, names and details wrap and the level meter sits below them only while active.

A room card has a test-sound button, one state capsule, and a vertical Room actions menu (3D room, settings, delete) at the trailing edge. The button is a green Join until this device is in the room, then a grey Leave. There is no separate Share switch: a Mac that has joined a room and is set to Send or Both (Settings → This device, or a row's ⋮ menu) sends its sound to the room; set to Receive it only plays. The card has a green outline while this device is in the room, thicker while sound is moving. Green is reserved for live sound. The bottom status bar appears only while there is a message or active audio. With developer diagnostics on, route tests and endpoint details sit in a collapsed “Connection diagnostics” disclosure under each paired device.

The local computer and its audio devices can be assigned to rooms. Paired devices are listed but remote movement requires an approved network control protocol. Audio-device sliders control real hardware output volume when macOS exposes it. Dragging does not grant microphone access or enable sharing.

## Startup

The window opens without waiting for Keychain. When macOS requires permission to read the saved signing key, the interface shows a short unlock message. Pairing and room movement wait for the existing identity; the app never silently substitutes a new identity.

## Verification

The macOS app and iOS simulator target compile. The local move, move-back, unknown-room rejection, and pairing approval tests pass. The Mac interface and actual route updates have been checked. The iPhone development build has been installed and launched on the connected device. The native drag gesture still needs a manual end-to-end check.

## Guests and roles

A room’s actions menu opens **Guests**. It shows the owner, the invited guests, anyone asking to join, and who can find the room (Invited only, Friends, Anyone nearby — the existing join policy). The owner invites paired devices and gives each a role: **Can listen** or **Can control**. A guest who can control may add or remove any device the owner can see; the owner’s device checks the role on every request. Only the owner edits guests, renames or deletes the room.

Guests are paired devices. A person’s own devices, signed in to the same Apple Account, are not guests: they are listed together as the owner and can each edit, re-staff or delete the room. Settings names the linked devices under Account. Roles do not yet gate who may receive room audio.

The New room sheet uses the same three choices, puts the name first and the place second, and states that joining never switches on a microphone.

## Pairing sheet

On iPhone the sheet opens with the camera running as the card’s background, ready to scan the other device’s code. This device’s own QR code and short code sit over it at 60% opacity. One white panel below holds the code field, Share, the Discover nearby switch and the nearby devices with a Pair button. There is no title or instruction text. On Mac, which has no scanner, the card keeps its slate background.

## Audio map (developer mode)

With developer diagnostics on, the header gains an **Audio map** button that swaps the main window between the rooms-and-devices list and the map. It is a place in the window, not a sheet.

The map is drawn by React Flow 11 inside a web view, from `Sources/SoundboundKit/Resources/AudioMap` (React 18.3.1 and reactflow 11.11.4, both MIT, bundled locally; the page loads nothing from the network and may not navigate). The app builds a snapshot four times a second and the page only draws it.

Each output in the room is one row: Source → Capture → (Playout buffer → Hardware) for an output on this device, or (Encrypt → Network interface → Network → Receive → Hardware) for one on a paired device. Cards carry the live figures: level meter, queued audio, buffer target, recoveries, network round trip and its half, OS output latency, I/O buffer, gains and hardware volume. Connections are labelled with the lag that applies to them and animate while sound moves. Each hardware card totals the delays that are actually measured and says it is a floor, not an end-to-end figure.

Three kinds of boundary are drawn around the cards' measured frames: each device, the Soundbound app inside it, and the local network between devices. Selecting a card shows its full notes below the map. Pan, zoom, fit and the minimap come from the library.

Wide device rows retain an idle meter in a shared column, including disconnected devices and host headers; absent level controls reserve their column so meters stay aligned. Room and host headers summarize their active components; recording takes priority and is red. All 32 amplitude bars receive history samples. Meter drawing captures the latest published samples on every update and uses a perceptual display scale so quiet audio remains visible. Narrow rows reserve that space for readable names and status. The iPhone room action reads Add device.

The map opens on **All rooms**: every room is a card between Capture and its outputs, and a device in two rooms appears under both. The picker narrows it to one room. The Source card names the applications making sound on this Mac even when nothing is shared to a room. While the map is open on a Mac, the Source card's meter shows what the Mac is playing, shared or not. Controls sit on the card they change: the Playout card has this device's buffer limits (starts at 5–40 ms, grows to at most 70 ms; defaults 10 and 60, remembered) and the Network interface card has Retest routes. Cards can be dragged, their boundaries follow, and Tidy up puts them back. The Capture card has a remembered 1–20 ms packet-limit slider (48–960 bytes of PCM), applied to subsequent delivery batches without restarting capture. Shorter hardware callbacks and test-tone packets remain shorter. The format stays at 24 kHz, mono, 16-bit; a route cannot be pinned by hand. Original Mac application playback branches directly from Source to macOS playout; Soundbound gain does not apply to that path. Buffer underruns are labelled as session counts and highlighted when nonzero.


## Meters

Settings → Meters chooses what every level meter draws (device rows, the menu-bar panel and the audio map): **Amplitude**, loudness over time, or **Frequency**, 24 pitch bands from 80 Hz to 10 kHz rising from the bottom. The choice travels to the person's other devices on the same Apple Account with the regular device refresh; the most recent change wins. Paired devices report their bands along with their level, so remote speakers draw frequencies too.

## Send, receive or both

Settings → This device → Sound on this device. **Send** only: the device shares sound to rooms and declines streams from other devices. **Receive** only: it plays what other devices send and will not start sharing. **Both** is the default. The setting belongs to the device and is not shared across the account.

The room’s Add device menu lists both microphones and speakers. Adding a microphone changes room membership; recording still starts explicitly and its meter is red while capturing.

On narrow screens, room headers place the room name and subtitle above a separate row containing the meter and controls. The Live/Off control retains its intrinsic horizontal size so the label cannot wrap into a tall capsule.

## How the audio map is built

Every device builds a description of only itself: its source and capture, each room it can send to, a playout card per own speaker, an encrypt card per speaker on another device, one network interface and one network card per device it sends to, and a receive card for each nearby paired device and own speaker. One hardware card stands for each speaker however many paths feed it. While a map is open, paired devices exchange these descriptions about once a second with the regular device refresh. The viewer stacks one block per device (its own first), puts every network card in a single network region, and draws a line from a sender's network card to the receive cards the other device lists for that sender. The line is live only when the sender is sending and the receiver reports receiving. A device that is not nearby, or is on an older build, has no block.
