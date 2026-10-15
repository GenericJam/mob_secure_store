defmodule MobSecureStore.File do
  @moduledoc """
  The off-phone backend (development, tests): one 0600 file per key in a 0700
  directory, `config :mob_secure_store, :dir` or else
  `Path.join(Mob.data_dir(), "mob_secure_store")`.

  Each file is named by the SHA-256 of its key, so any key maps to one safe
  filename and no two keys share one. Not encrypted: file permissions are the
  only protection, which is why phones never use it.
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
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    # Made 0600 before the secret goes in, synced, then renamed over the old
    # file, so a reader sees the old value or the new one, never a part.
    result =
      with :ok <- ensure_dir(),
           {:ok, io} <- :file.open(tmp, [:write, :raw, :binary, :exclusive]) do
        written =
          with :ok <- Elixir.File.chmod(tmp, 0o600),
               :ok <- :file.write(io, value),
               do: :file.sync(io)

        :ok = :file.close(io)

        with :ok <- written, do: :file.rename(tmp, path)
      end

    if result != :ok, do: Elixir.File.rm(tmp)
    result
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
