defmodule MobSecureStore.File do
  @moduledoc """
  The off-phone backend (development, tests): one 0600 file per key in a 0700
  directory, `config :mob_secure_store, :dir` or else
  `Path.join(Mob.data_dir(), "mob_secure_store")`.

  Each file is named by the SHA-256 of its key, so any key maps to one safe
  filename and no two keys share one. A write goes to a 0600 temporary file
  that is synced and renamed over the old one, so a reader sees the old value
  or the new one, never part of one; the directory itself isn't synced (Erlang
  can't), so a power cut right after `put/2` may lose the rename. Not
  encrypted: file permissions are the only protection, which is why a phone
  never uses this backend.
  """
  @behaviour MobSecureStore

  @impl true
  def get(key) do
    case Elixir.File.read(path(key)) do
      {:ok, value} -> {:ok, value}
      {:error, :enoent} -> :error
      {:error, _} = error -> error
    end
  end

  @impl true
  def put(key, value) do
    path = path(key)
    tmp = "#{path}.#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}.tmp"

    with :ok <- ensure_dir(),
         {:ok, io} <- :file.open(tmp, [:write, :raw, :binary, :exclusive]) do
      # This call created tmp, so it removes it unless it was renamed.
      result =
        try do
          with :ok <- Elixir.File.chmod(tmp, 0o600),
               :ok <- :file.write(io, value),
               :ok <- :file.sync(io),
               do: :file.close(io)
        after
          # Already closed is a no-op; a close error reaches the caller above.
          :file.close(io)
        end

      result = with :ok <- result, do: :file.rename(tmp, path)
      if result != :ok, do: Elixir.File.rm(tmp)
      result
    end
  end

  @impl true
  def delete(key) do
    case Elixir.File.rm(path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "The directory the files are kept in."
  @spec dir() :: Path.t()
  def dir do
    Application.get_env(:mob_secure_store, :dir) ||
      Path.join(Mob.data_dir(), "mob_secure_store")
  end

  defp ensure_dir do
    dir = dir()

    with :ok <- Elixir.File.mkdir_p(dir), do: Elixir.File.chmod(dir, 0o700)
  end

  defp path(key),
    do: Path.join(dir(), :crypto.hash(:sha256, key) |> Base.encode16(case: :lower))
end
