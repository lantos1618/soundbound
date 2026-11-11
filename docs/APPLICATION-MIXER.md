# Application mixer

The Mac menu-bar panel lists applications that Core Audio reports as producing audio. Moving an app’s volume below 100% creates a private process tap, mutes the original output while the tap is running, applies gain, and plays the adjusted audio on the Mac’s current output. At 100%, Reset, or app shutdown, the tap is removed and normal output resumes.

This requires macOS 14.2 or later and System Audio Recording permission. Audio stays on the Mac; this path does not save or send application audio over the network. It supports matching 32-bit float input/output formats and rejects unsupported formats rather than guessing a conversion.

The hardware volume slider controls the selected physical device separately. Its writes are verified against Core Audio and rapid changes retain the latest requested value.

Room membership and activity are separate. A device can belong to multiple rooms, but this host selects one active room at a time. Turning it off stops the current Soundbound stream without deleting memberships. This selector does not yet synchronize multiple speakers or mix multiple network sources.

Implementation: [Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
