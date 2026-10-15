%{
  name: :mob_secure_store,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  description:
    "Secure storage for small secrets: the iOS Keychain, Android EncryptedSharedPreferences",
  # `mix mob.selftest`: a value round-trips through the NIF on the device.
  selftest: MobSecureStore.SelfTest,
  nifs: [
    # iOS: C over Security.framework's SecItem* (the Keychain). platform: :ios
    # keeps it out of the Android build.
    %{module: :mob_secure_store_nif, native_dir: "priv/native/ios", lang: :c, platform: :ios},
    # Android: C JNI calling io.mob.securestore.MobSecureStoreBridge
    # (EncryptedSharedPreferences). platform: :android keeps it out of iOS.
    %{module: :mob_secure_store_nif, native_dir: "priv/native/jni", lang: :c, platform: :android}
  ],
  android: %{
    bridge_kt: "priv/native/android/MobSecureStoreBridge.kt",
    bridge_class: "io.mob.securestore.MobSecureStoreBridge",
    permissions: [],
    # Jetpack Security: EncryptedSharedPreferences + MasterKey (Keystore).
    gradle_deps: ["androidx.security:security-crypto:1.1.0-alpha06"]
  },
  ios: %{
    frameworks: ["Security"]
  },
  # Printed on every `mix mob.deploy --native` of the host.
  host_requirements: [
    "iOS simulator: the Keychain refuses an app without entitlements " <>
      "({:error, {:sec, -34018}}, errSecMissingEntitlement), and the simulator reads them from " <>
      "the binary's __TEXT,__entitlements section, not its ad-hoc signature. Add " <>
      "ios/simulator_entitlements.plist (application-identifier and keychain-access-groups " <>
      "set to the bundle id; not named *.entitlements, which device signing would pick up) and, " <>
      "in ios/build.zig's addLink, pass it before \"-o\": " <>
      ~S|run.addArgs(&.{ "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements", "-Xlinker" }); | <>
      "run.addFileArg(<that plist>);. Device builds need nothing: mob_dev signs them with the " <>
      "provisioning profile's entitlements. See the README."
  ]
}
