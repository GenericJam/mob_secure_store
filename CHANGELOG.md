# Changelog

All notable changes to **mob_secure_store** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `MobSecureStore.put/2`, `get/1`, `delete/1`: small secrets in the iOS
  Keychain and Android EncryptedSharedPreferences (Keystore master key), from
  Operator's secure-store NIF. Values are any binary.
- Host fallback `MobSecureStore.File`: one 0600 file per key in a 0700
  directory under the app's data dir.
- Fails closed on a phone whose app was built without the NIF
  (`{:error, :secure_store_unavailable}`).
- `MobSecureStore.SelfTest` for `mix mob.selftest`.
- Host requirement for the iOS simulator's Keychain entitlements.
