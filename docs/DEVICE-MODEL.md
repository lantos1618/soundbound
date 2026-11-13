# Physical devices first

Product direction: use an AirTag-like object model for speakers, headphones, microphones, and host devices. This is an interaction analogy, not an integration with Apple's Find My network or a location-tracking claim.

A physical device should have one persistent identity even when it exposes several audio inputs and outputs. Input and output capabilities belong to that device; they should not appear as unrelated objects. A Bluetooth address or local audio UID is a local hardware mapping, not a user's global identity.

The device view should make these things understandable:

- Name and owner.
- Available now, disconnected, or last seen at an actually observed time.
- Its chosen room/group.
- The host currently controlling its audio, only when verified.
- Request control, accept/decline, and release actions.
- Per-device rules for approval, change notifications, and disconnect behavior.

Room membership is organization, not proof of physical location. Local audio enumeration is not proof that a device is playing sound, and an offline device must not be presented as controllable. A missing device can retain its name and group without pretending that it is reachable.

## Current behavior

Inputs and outputs are nested under the host that reports them. Nearby paired hosts exchange signed inventory snapshots every five seconds; this metadata is visible on the local network. A remote row reports the other host’s state and does not grant remote control of that output.

After automatic account linking, the initiator requests inventory only after verifying the final account reply. The responder requests the initiator's inventory when that first trusted request arrives. Inventory requests time out after five seconds; missed replies, disconnects and stale callbacks cannot block a later refresh for the generic network timeout. An empty inventory is still a successful reply and does not trigger a reciprocal polling loop.

Dragging a host into a room includes its attached components. Components can also have independent room memberships. Removing the parent from one room does not erase those independent assignments. Room definitions and layout assignments are mirrored from their creating device to nearby paired devices. The creator remains the editor; this does not grant remote audio access.

Local route changes can request confirmation before Soundbound performs them. Changes initiated by Apple are observed afterward. A disconnect alone cannot prove which other host took ownership, so Soundbound must not describe it as an intercepted transfer request.

One source can stream encrypted audio to one paired receiver after approval. Multi-source mixing, automatic iPhone route selection, and synchronized room playback remain future work.

Bluetooth headphones can be dropped on a host to request a move. The receiving host must approve. A Mac attempts its existing verified Bluetooth connection flow; iPhone presents Apple’s audio chooser. Built-in, wired, virtual, and Continuity endpoints cannot be reassigned between hosts.
