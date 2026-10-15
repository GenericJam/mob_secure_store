# mob_secure_store

Small secrets (tokens, API keys) for [Mob](https://github.com/GenericJam/mob)
apps, kept in the platform's secure store: the iOS Keychain and, on Android,
EncryptedSharedPreferences under an Android Keystore master key. On the host
(development, tests) each value is a 0600 file.

```elixir
:ok = MobSecureStore.put("anthropic", token)
{:ok, ^token} = MobSecureStore.get("anthropic")
:ok = MobSecureStore.delete("anthropic")
:error = MobSecureStore.get("anthropic")
```

## API

| Call | Returns |
|--|--|
| `MobSecureStore.put(key, value)` | `:ok` once written (not queued), or `{:error, reason}` |
| `MobSecureStore.get(key)` | `{:ok, value}`, `:error` when nothing is stored, or `{:error, reason}` when the store failed |
| `MobSecureStore.delete(key)` | `:ok` (also when the key is absent), or `{:error, reason}` |
| `MobSecureStore.backend()` | the module in use (see below) |

Keys are non-empty UTF-8 strings; values are any binary. Anything else raises
`ArgumentError`. The store is for small values: each one is a Keychain item or
a preferences entry.

A store failure is never reported as an absent key: `:error` means "nothing
there", `{:error, reason}` means "couldn't tell". Reasons are
`{:sec, os_status}` (Security.framework on iOS), `{:jni, reason}` (Android:
`:no_jenv`, `:bridge_not_registered`, `:alloc`, `:call_failed`,
`:commit_failed`), `:secure_store_unavailable`, or a file error on the host.

## Where values live

| Running on | Backend | Storage |
|--|--|--|
| Android | `MobSecureStore.Native` | EncryptedSharedPreferences (`mob_secure_store` preferences file; keys AES-256-SIV, values AES-256-GCM) under a Keystore master key |
| iOS | `MobSecureStore.Native` | Keychain generic passwords, service `mob_secure_store`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (not synced, not restored to another device) |
| A phone whose app was built without the NIF | `MobSecureStore.Unavailable` | nothing: every call is `{:error, :secure_store_unavailable}` |
| The host | `MobSecureStore.File` | one 0600 file per key (named by the key's SHA-256) in a 0700 directory: `config :mob_secure_store, :dir`, else `Mob.data_dir()/mob_secure_store` |

The store fails closed on a phone. If the plugin was activated after the app's
last native build and only BEAMs were deployed, the NIF isn't in the app, and
`MobSecureStore` refuses to store anything rather than write secrets to plain
files. It logs an error once; `mix mob.deploy --native` fixes it.

`config :mob_secure_store, :backend, MyFake` replaces the backend (any module
implementing the `MobSecureStore` behaviour), e.g. in a host app's tests.

## Installing

```elixir
# mix.exs
{:mob_secure_store, github: "GenericJam/mob_secure_store"}
# or, from a local checkout:
{:mob_secure_store, path: "../mob_secure_store"}

# mob.exs
config :mob, :plugins, [..., :mob_secure_store]
```

Then `mix deps.get` and `mix mob.deploy --native`: the plugin has native code,
so a BEAM-only deploy doesn't bring it.

### Trust

mob_dev refuses to build with an activated plugin whose signature it can't
verify. mob_secure_store hasn't been released yet, so a checkout has no
`priv/mob_plugin.sig`. Until it's published (signed in CI with the shared mob
release key, like the other first-party plugins), let the host build it
unsigned:

```elixir
# mob.exs
config :mob, :acknowledge_unsafe_plugins, [:mob_secure_store]
```

Every build then prints a warning banner naming it. Once it's on Hex, drop
that line and trust the release key instead: add
`mob_secure_store: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="` to
`config :mob, :trusted_plugins` (the same fingerprint as the other first-party
plugins), or run `mix mob.plugin.trust mob_secure_store`.

### Android

Nothing to do. The manifest adds `androidx.security:security-crypto` to the
Gradle build and registers `io.mob.securestore.MobSecureStoreBridge`, which the
generated `MobPluginBootstrap` initialises from `MainActivity.onCreate`, before
the BEAM starts.

### iOS simulator

The simulator's Keychain refuses an app that has no entitlements
(`{:error, {:sec, -34018}}`, errSecMissingEntitlement), and it reads them from
the binary's `__TEXT,__entitlements` section, not from its ad-hoc signature.
mob's simulator builds don't add one, so the host does:

1. Add `ios/simulator_entitlements.plist`, with your bundle id. Don't name it
   `*.entitlements`: device signing uses the first `ios/*.entitlements` it finds.

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>application-identifier</key>
       <string>com.example.my_app</string>
       <key>keychain-access-groups</key>
       <array>
           <string>com.example.my_app</string>
       </array>
   </dict>
   </plist>
   ```

2. Link it in `ios/build.zig`. Add a field to `LinkOptions`, pass it where
   `addLink` is called, and add the section in `addLink` before `-o`:

   ```zig
   // LinkOptions
   simulator_entitlements: std.Build.LazyPath,

   // the addLink(b, binary_step, .{ ... }) call
   .simulator_entitlements = .{ .cwd_relative = b.fmt("{s}/simulator_entitlements.plist", .{project_ios_dir}) },

   // addLink, before run.addArg("-o")
   run.addArgs(&.{ "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements", "-Xlinker" });
   run.addFileArg(opts.simulator_entitlements);
   ```

Device builds need neither: mob_dev signs them with the provisioning profile's
entitlements, whose application identifier gives the app its Keychain access
group. The plugin manifest lists this step as a host requirement, so
`mix mob.deploy --native` prints it.

## Checking it on a device

`mix mob.selftest --device <id>` runs `MobSecureStore.SelfTest` in the
deployed app: a value goes through the NIF into the platform store, is read
back and deleted.

## Provenance

The native code is Operator's secure store (`c_src/operator_secure_store.c`,
`OperatorSecureStore.kt`, `Operator.SecureStore`), which was ported from
muster_app's. Changes from Operator's: one NIF source per platform instead of
`#ifdef`s; the Android side passes byte arrays (Operator's passed Java strings,
so values were UTF-8 only and cut at a NUL) and stores values Base64-encoded;
a missing key is `:error` instead of `{:ok, nil}`; the Keychain service and
preferences file are `mob_secure_store`; store calls run on dirty IO
schedulers.

## License

MIT; see [LICENSE](LICENSE).
