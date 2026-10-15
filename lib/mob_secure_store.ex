defmodule MobSecureStore do
  @moduledoc """
  Small secrets (tokens, API keys) kept in the platform's secure store.

      :ok = MobSecureStore.put("anthropic", token)
      {:ok, ^token} = MobSecureStore.get("anthropic")
      :ok = MobSecureStore.delete("anthropic")
      :error = MobSecureStore.get("anthropic")

  Where the values live depends on where the code runs (`backend/0`):

    * **Android**: EncryptedSharedPreferences under an Android Keystore master
      key (`MobSecureStore.Native`).
    * **iOS**: the Keychain, as generic-password items readable after the
      device's first unlock, never synced or backed up to another device
      (`MobSecureStore.Native`).
    * **A phone whose app was built without this plugin's NIF** (the plugin
      was activated after the last native build, and only BEAMs were
      deployed): every call is `{:error, :secure_store_unavailable}`
      (`MobSecureStore.Unavailable`). The store fails closed instead of
      writing secrets to plain files. Rebuild with `mix mob.deploy --native`.
    * **The host** (development, tests): one 0600 file per key in a 0700
      directory under the app's data dir (`MobSecureStore.File`).

  `config :mob_secure_store, :backend, Module` replaces the backend (a module
  implementing this behaviour), e.g. a fake in a host app's tests.

  Keys are non-empty UTF-8 strings; values are any binary. A key or value of
  another shape raises `ArgumentError`.
  """

  require Logger

  @typedoc "Why the store couldn't do what was asked."
  @type reason ::
          :secure_store_unavailable
          | {:sec, integer()}
          | {:jni, atom()}
          | File.posix()
          | term()

  @doc "The value at `key`, or `:error` when there is none."
  @callback get(key :: String.t()) :: {:ok, binary()} | :error | {:error, reason()}

  @doc "Upserts `key`, durably: `:ok` means written, not queued."
  @callback put(key :: String.t(), value :: binary()) :: :ok | {:error, reason()}

  @doc "Removes `key`; removing an absent key is `:ok`."
  @callback delete(key :: String.t()) :: :ok | {:error, reason()}

  @doc """
  The value stored at `key`.

  `:error` when nothing is stored there; `{:error, reason}` when the store
  itself failed (see `t:reason/0`), so a failure is never mistaken for an
  absent key.
  """
  @spec get(String.t()) :: {:ok, binary()} | :error | {:error, reason()}
  def get(key) do
    check_key!(key)
    backend().get(key)
  end

  @doc "Stores `value` at `key`, replacing what was there. `:ok` means it's written."
  @spec put(String.t(), binary()) :: :ok | {:error, reason()}
  def put(key, value) do
    check_key!(key)

    unless is_binary(value),
      do: raise(ArgumentError, "a MobSecureStore value must be a binary, got: #{inspect(value)}")

    backend().put(key, value)
  end

  @doc "Removes `key`. Removing a key that isn't there is `:ok`."
  @spec delete(String.t()) :: :ok | {:error, reason()}
  def delete(key) do
    check_key!(key)
    backend().delete(key)
  end

  @doc """
  The backend in effect: the configured one, else the one for this platform
  (detected once per VM).
  """
  @spec backend() :: module()
  def backend do
    case Application.fetch_env(:mob_secure_store, :backend) do
      {:ok, module} -> module
      :error -> detected_backend()
    end
  end

  @doc false
  # The backend for `platform`, given whether the NIF is linked into the app.
  @spec backend_for(:android | :ios | :host, boolean()) :: module()
  def backend_for(:host, _nif_linked?), do: MobSecureStore.File
  def backend_for(_phone, true), do: MobSecureStore.Native
  def backend_for(_phone, false), do: MobSecureStore.Unavailable

  defp detected_backend do
    with :unknown <- :persistent_term.get({__MODULE__, :backend}, :unknown) do
      platform = platform()
      module = backend_for(platform, platform != :host and :mob_secure_store_nif.available())

      if module == MobSecureStore.Unavailable,
        do:
          Logger.error(
            "[mob_secure_store] the app was built without the secure store NIF: " <>
              "secrets can't be kept until it's rebuilt (mix mob.deploy --native)"
          )

      :persistent_term.put({__MODULE__, :backend}, module)
      module
    end
  end

  # mob core's NIF says which phone this is; off the phone it isn't loaded.
  defp platform do
    case :mob_nif.platform() do
      platform when platform in [:android, :ios] -> platform
      _ -> :host
    end
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> :host
  end

  defp check_key!(key) do
    unless is_binary(key) and key != "" and String.valid?(key),
      do:
        raise(
          ArgumentError,
          "a MobSecureStore key must be a non-empty UTF-8 string, got: #{inspect(key)}"
        )

    :ok
  end
end
