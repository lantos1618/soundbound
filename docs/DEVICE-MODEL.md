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

The next network work must connect this device model to authenticated presence and explicit control requests, followed by encrypted media transport. The existing local controls and signed pairing are foundations; they are not yet a working audio mesh.
