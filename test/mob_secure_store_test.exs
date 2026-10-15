defmodule MobSecureStoreTest do
  # async: false: the backend and directory are app-wide config.
  use ExUnit.Case, async: false

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  setup do
    dir =
      Path.join(System.tmp_dir!(), "mob_secure_store_test_#{System.unique_integer([:positive])}")

    Application.put_env(:mob_secure_store, :dir, dir)

    on_exit(fn ->
      Application.delete_env(:mob_secure_store, :dir)
      Application.delete_env(:mob_secure_store, :backend)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  describe "on the host" do
    test "detects the file backend" do
      assert MobSecureStore.backend() == MobSecureStore.File
    end

    test "put/get/delete round-trip any binary, and absent is :error" do
      value = <<0, 255, "tok", 0, 1, 2>>

      assert MobSecureStore.get("anthropic") == :error
      assert MobSecureStore.put("anthropic", value) == :ok
      assert MobSecureStore.get("anthropic") == {:ok, value}

      assert MobSecureStore.put("anthropic", "") == :ok
      assert MobSecureStore.get("anthropic") == {:ok, ""}

      assert MobSecureStore.delete("anthropic") == :ok
      assert MobSecureStore.get("anthropic") == :error
      assert MobSecureStore.delete("anthropic") == :ok
    end

    test "keys are independent, including ones that differ only in unsafe characters" do
      keys = ["a/b", "a_b", "a b", "../a", "ключ", String.duplicate("k", 1000)]

      for key <- keys, do: assert(MobSecureStore.put(key, "v:" <> key) == :ok)
      for key <- keys, do: assert(MobSecureStore.get(key) == {:ok, "v:" <> key})

      assert MobSecureStore.delete("a/b") == :ok
      assert MobSecureStore.get("a/b") == :error
      assert MobSecureStore.get("a_b") == {:ok, "v:a_b"}
    end

    test "values are files only the owner can read, in a directory only the owner can list",
         %{dir: dir} do
      assert MobSecureStore.put("../escape", "secret") == :ok

      assert [file] = File.ls!(dir)
      assert File.stat!(Path.join(dir, file)).mode |> Bitwise.band(0o777) == 0o600
      assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
    end

    test "a failed write is an error, not :ok", %{dir: dir} do
      # A regular file where the directory should be.
      File.write!(dir, "")

      assert {:error, _} = MobSecureStore.put("k", "v")
      assert MobSecureStore.get("k") == {:error, :enotdir}
    end
  end

  describe "argument checks" do
    test "a key must be a non-empty UTF-8 string" do
      for key <- ["", <<255, 254>>, :atom, nil, ~c"chars"] do
        assert_raise ArgumentError, fn -> MobSecureStore.get(key) end
        assert_raise ArgumentError, fn -> MobSecureStore.put(key, "v") end
        assert_raise ArgumentError, fn -> MobSecureStore.delete(key) end
      end
    end

    test "a value must be a binary" do
      for value <- [~c"chars", nil, 1] do
        assert_raise ArgumentError, fn -> MobSecureStore.put("k", value) end
      end
    end
  end

  describe "backend selection" do
    test "a linked NIF is the store; files only off the phone; a phone without the NIF fails closed" do
      assert MobSecureStore.backend_for(:phone, true) == MobSecureStore.Native
      assert MobSecureStore.backend_for(:phone, false) == MobSecureStore.Unavailable
      assert MobSecureStore.backend_for(:host, false) == MobSecureStore.File
    end

    test "on a phone without the NIF every call refuses, even with the file backend configured",
         %{dir: dir} do
      on_phone_without_nif()

      ExUnit.CaptureLog.capture_log(fn -> assert_refuses_everything(dir) end)
    end

    test "a configured backend wins over detection" do
      Application.put_env(:mob_secure_store, :backend, MobSecureStore.Unavailable)
      assert MobSecureStore.backend() == MobSecureStore.Unavailable
      assert MobSecureStore.put("k", "v") == {:error, :secure_store_unavailable}
    end

    # Guards the .erl stub (VacuousTest can't see Erlang modules as app code).
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the NIF isn't linked on the host: available/0 is false" do
      refute :mob_secure_store_nif.available()
    end
  end

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "passes the pre-publish validator", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "one NIF module, a C source per platform, both present", %{manifest: m} do
      assert [ios, android] = m.nifs
      assert {ios.module, ios.platform, ios.lang} == {:mob_secure_store_nif, :ios, :c}

      assert {android.module, android.platform, android.lang} ==
               {:mob_secure_store_nif, :android, :c}

      for nif <- m.nifs do
        assert File.exists?(Path.join([@plugin_dir, nif.native_dir, "mob_secure_store_nif.c"]))
      end
    end
  end

  defp assert_refuses_everything(dir) do
    for configured <- [nil, MobSecureStore.File] do
      if configured, do: Application.put_env(:mob_secure_store, :backend, configured)

      assert MobSecureStore.backend() == MobSecureStore.Unavailable
      assert MobSecureStore.put("k", "v") == {:error, :secure_store_unavailable}
      assert MobSecureStore.get("k") == {:error, :secure_store_unavailable}
      assert MobSecureStore.delete("k") == {:error, :secure_store_unavailable}
    end

    refute File.exists?(dir)
  end

  # Detection as on a phone whose app was built without the NIF: mob's device
  # launcher sets MOB_BEAMS_DIR, and the NIF isn't linked on the host.
  defp on_phone_without_nif do
    System.put_env("MOB_BEAMS_DIR", "/nonexistent")
    :persistent_term.erase({MobSecureStore, :environment})

    on_exit(fn ->
      System.delete_env("MOB_BEAMS_DIR")
      :persistent_term.erase({MobSecureStore, :environment})
    end)
  end
end
