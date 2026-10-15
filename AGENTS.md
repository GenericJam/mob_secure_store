# AGENTS.md — orientation for AI agents working on mob_secure_store

You're in **mob_secure_store**, a Mob plugin that keeps small secrets in the platform's secure store: `MobSecureStore.put/2`, `get/1`, `delete/1` over the iOS Keychain and Android EncryptedSharedPreferences, a 0600 file on the host. The README has the API and the host setup; this file is what you need to change it safely.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view (repo topology, plugin manifest, driving a running app) and [`~/code/mob/guides/plugins.md`](../mob/guides/plugins.md) for plugin signing and activation.

> **Keep this file current.** When you change the result contract, either native side, or hit a gotcha, fix it here in the same commit.

## Anatomy

* `lib/mob_secure_store.ex` — the public API, the behaviour every backend implements, argument checks, and backend selection (`backend/0`, `backend_for/2`).
* `lib/mob_secure_store/native.ex` — `MobSecureStore.Native` (the NIF; maps the NIF's `:not_found` to `:error`) and `MobSecureStore.Unavailable` (refuses everything).
* `lib/mob_secure_store/file.ex` — `MobSecureStore.File`, the host backend.
* `lib/mob_secure_store/self_test.ex` — `mix mob.selftest` round-trip.
* `src/mob_secure_store_nif.erl` — the NIF stub. `on_load` tolerates a missing NIF; `available/0` answers `false` unless the NIF replaced it.
* `priv/native/ios/mob_secure_store_nif.c` — Keychain (SecItem*), `platform: :ios`.
* `priv/native/jni/mob_secure_store_nif.c` — JNI calls into the Kotlin bridge, `platform: :android`.
* `priv/native/android/MobSecureStoreBridge.kt` — EncryptedSharedPreferences; `register()` caches the class for the C side, `setActivity/1` opens the store. Both run from the generated `MobPluginBootstrap.registerAll` in `MainActivity.onCreate`, before the BEAM starts.
* `priv/mob_plugin.exs` — manifest: two C NIFs (one per platform, same module), the bridge, the `security-crypto` Gradle dep, `Security` framework, the iOS-simulator host requirement, the self-test.

## Rules that matter here

1. **Fail closed on a phone.** `backend_for/2` must never return `MobSecureStore.File` for `:android` or `:ios`. A phone without the NIF gets `Unavailable`. A misdetected platform that falls back to files would write secrets in plain text; detection goes through `:mob_nif.platform/0`, and anything that isn't `:android`/`:ios` is the host.
2. **A store failure is not an absent key.** `get/1` returns `:error` only for "nothing stored". Every native failure is `{:error, _}`; the Kotlin bridge throws (→ `{:jni, :call_failed}`) when the store didn't open, rather than returning null.
3. **Keychain attributes.** `kSecAttrAccessible` is set on add only, never in the match query (it would become a filter and orphan items if it ever changed). Upsert is add-then-update-on-duplicate, not the reverse (races).
4. **Bytes across JNI, not strings.** Values are arbitrary binaries; the bridge Base64-encodes them for SharedPreferences. Don't reintroduce `NewStringUTF` (modified UTF-8, cuts at NUL).
5. **iOS simulator needs host entitlements** (`-34018` otherwise); see the README. It's a host build change, not something this plugin can ship.
6. **Native changes need a native build and a device.** `mix test` covers the Elixir half only. Re-verify with a host app on an Android emulator and an iOS simulator: `mix mob.deploy --native --device <id>` and `mix mob.selftest --device <id>`, plus a value surviving an app kill and relaunch.
7. **No compile-time `~r//` literals** in `lib/` (the device runs OTP 28).

## Testing

```bash
mix test
mix format --check-formatted
mix credo --strict
mix mob.validate_plugin
```

## Release

Not released yet; no release workflow. Version bumps and Hex publishes need Kevin's approval. When it's released, add the first-party `release.yml` (as in `mob_biometric`), which signs with the shared mob key (`priv/mob_plugin.pub` is that key) and publishes on a version bump. Never commit `priv/mob_plugin.sig`.
