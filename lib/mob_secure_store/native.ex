defmodule MobSecureStore.Native do
  @moduledoc """
  The phone's backend: the `:mob_secure_store_nif` NIF, linked into the app by
  the native build. EncryptedSharedPreferences under an Android Keystore
  master key on Android, the Keychain on iOS.

  Errors are `{:error, {:sec, os_status}}` from Security.framework on iOS and
  `{:error, {:jni, reason}}` on Android, where reason is `:no_jenv`,
  `:bridge_not_registered` (the bridge's `register()` didn't run before the
  BEAM started), `:alloc`, `:call_failed` (the bridge threw, e.g. the
  encrypted preferences couldn't be opened; it logs why under the
  `MobSecureStore` logcat tag) or `:commit_failed`.
  """
  @behaviour MobSecureStore

  @impl true
  def get(key) do
    case :mob_secure_store_nif.store_get(key) do
      :not_found -> :error
      result -> result
    end
  end

  @impl true
  def put(key, value), do: :mob_secure_store_nif.store_put(key, value)

  @impl true
  def delete(key), do: :mob_secure_store_nif.store_delete(key)
end

defmodule MobSecureStore.Unavailable do
  @moduledoc """
  The phone's backend when the app was built without the NIF: refuses
  everything, so secrets are never written anywhere less safe.
  """
  @behaviour MobSecureStore

  @impl true
  def get(_key), do: {:error, :secure_store_unavailable}

  @impl true
  def put(_key, _value), do: {:error, :secure_store_unavailable}

  @impl true
  def delete(_key), do: {:error, :secure_store_unavailable}
end
