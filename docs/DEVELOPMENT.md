# Development identity

Development builds keep the device signing identity in a local JSON file. They do not read or write Keychain.

- macOS: `~/Library/Application Support/Soundbound/Development/identity.json`
- iOS: `Library/Application Support/Soundbound/Development/identity.json` inside the app container

The file is created with permissions `0600` in a `0700` directory and is excluded from backups. The private key is not an environment variable, is not included in the app bundle, and must not be committed. The same file is reused across rebuilds. A corrupt or invalid file causes an error; it is not silently replaced.

Creation is serialized by a local file lock, then written atomically. The lock contains no key material. Do not copy this identity between devices: each device needs its own signing key.

## Build modes

`bash scripts/build.sh` creates an optimized development build with `SOUNDBOUND_DEVELOPMENT`. iOS Debug builds define `DEBUG`. Both select JSON storage.

`SOUNDBOUND_PRODUCTION=1 bash scripts/build.sh` and iOS Release builds use Keychain. Development and production store their local app state separately.

## First switch from Keychain

The development identity is separate from the previous Keychain identity. Existing locally-created rooms and audio assignments are copied to development state, and any paired peers must approve this new identity once. The production Keychain and saved production state are left intact. Subsequent development rebuilds keep the same file and identity.

Tests check identity stability, signing, file permissions, corrupt-file handling, and rejection of symlink identity files.
