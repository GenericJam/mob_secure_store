defmodule MobSecureStore.SelfTest do
  @moduledoc """
  On-device proof (`mix mob.selftest`) that the secure store works in this
  build: a value round-trips through the NIF into the Keychain or
  EncryptedSharedPreferences and is deleted again.
  """
  @behaviour Mob.Plugin.SelfTest

  alias MobSecureStore.Native

  @key "mob_secure_store.selftest"
  @value <<"selftest", 0, 255>>

  @impl true
  def run(%{platform: platform}) do
    with {:linked, true} <- {:linked, :mob_secure_store_nif.available()},
         {:put, :ok} <- {:put, Native.put(@key, @value)},
         {:get, {:ok, @value}} <- {:get, Native.get(@key)},
         {:delete, :ok} <- {:delete, Native.delete(@key)},
         {:gone, :error} <- {:gone, Native.get(@key)} do
      :pass
    else
      {:linked, false} ->
        {:fail, "the mob_secure_store NIF isn't linked into this #{platform} build"}

      {step, result} ->
        {:fail, "#{step} on #{platform} returned #{inspect(result)}#{hint(result)}"}
    end
  end

  defp hint({:error, {:sec, -34_018}}),
    do: " (errSecMissingEntitlement: see the iOS simulator host requirement in the README)"

  defp hint(_), do: ""
end
