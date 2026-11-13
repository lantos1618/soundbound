# Application mixer

The Mac menu-bar panel lists applications that Core Audio reports as producing audio. Moving an app’s volume below 100% creates a private process tap, mutes the original output while the tap is running, applies gain, and plays the adjusted audio on the Mac’s current output. At 100%, Reset, or app shutdown, the tap is removed and normal output resumes.

This requires macOS 14.2 or later and System Audio Recording permission. These volume controls remain local. A separate **Share Mac audio** action now captures a mix of other running applications with an unmuted private process tap and broadcasts it to the active room. It excludes Soundbound's own process so received streams cannot be recaptured and forwarded in a loop. The tap keeps original local playback; a bounded conversion queue produces PCM16 mono at 24 kHz for the current encrypted transport. Local per-app volume controls and room broadcast gain are separate.

The hardware volume slider controls the selected physical device separately. Its writes are verified against Core Audio and rapid changes retain the latest requested value.

Endpoint rows also expose saved Soundbound software gains regardless of hardware-volume support or connection state. **Mic gain** attenuates local capture before recording or transmission. **Playback** attenuates Soundbound playback; **Device volume** remains the separate OS/hardware control. Remote rows expose **Send level** for this sender's stream and **Recording** for microphone clips received locally. Input and output gains are independent, range from mute to 100%, and do not activate a microphone or connect a device.

Room membership and activity are separate. A device can belong to multiple rooms, but this host selects one active room at a time. Turning it off stops outgoing and incoming room audio without deleting memberships. Each online, paired output in the active room gets a separate encrypted connection, and each receiver must activate that room too. This does not synchronize speakers or apply a shared limiter to simultaneous sources. The new application broadcast path still requires hardware listening tests.

Implementation: [Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
