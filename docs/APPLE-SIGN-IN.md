# Sign in with Apple

Signed development builds support native Apple authorization on macOS and iOS. No app-specific password is required.

`bash scripts/build.sh` builds the provisioned Mac app. Open the iOS Xcode project to run it on a phone. Both targets require the Sign in with Apple capability and a valid development team/profile. `SOUNDBOUND_SIGNED=0` makes an offline ad-hoc Mac build with Apple login disabled.

The app retains its authorization controller and presents from the active Settings window. It checks request state, observes credential revocation, and checks the saved user identifier with Apple when returning to the app. Only display metadata is cached; authorization and identity tokens are not persisted.

This is local account sign-in. It does not grant permissions to rooms on another device. Account-wide friendships and shared ownership require a server that verifies Apple tokens and maps accounts to device keys. Until then, paired-device approval and the creating device's room permissions remain authoritative.
