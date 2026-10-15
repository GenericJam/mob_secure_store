defmodule MobSecureStore.SelfTest do
  @moduledoc """
  On-device proof (`mix mob.selftest`) that the secure store works in this
  build: a value round-trips through the NIF into the Keychain or
  EncryptedSharedPreferences and is deleted again.
  """
  @behaviour Mob.Plugin.SelfTest

  alias MobSecureStore.Native

  @value <<"selftest", 0, 255>>

  @impl true
  def run(%{platform: platform}) do
    if :mob_secure_store_nif.available() do
      # A fresh key, so the test can't touch a value the app keeps.
      key = "mob_secure_store.selftest." <> Base.encode16(:crypto.strong_rand_bytes(8))

      try do
        round_trip(key, platform)
      after
        Native.delete(key)
      end
    else
      {:fail, "the mob_secure_store NIF isn't linked into this #{platform} build"}
    end
  end

  defp round_trip(key, platform) do
    with {:put, :ok} <- {:put, Native.put(key, @value)},
         {:get, {:ok, @value}} <- {:get, Native.get(key)},
         {:delete, :ok} <- {:delete, Native.delete(key)},
         {:gone, :error} <- {:gone, Native.get(key)} do
      :pass
    else
      {step, result} ->
        {:fail, "#{step} on #{platform} returned #{inspect(result)}#{hint(result)}"}
    end
  end

  defp hint({:error, {:sec, -34_018}}),
    do: " (errSecMissingEntitlement: see the iOS simulator host requirement in the README)"

  defp hint(_), do: ""
end
