defmodule SymphonyElixir.Bindle.Owner do
  @moduledoc """
  Persisted, stable, deployment-local owner-identity string used as every `bindle work
  claim`/`release` call's `--owner` argument. Generated once and reused across restarts of the same
  deployment — new state; nothing existing in Symphony is repurposed for this (FR-011).
  """

  @id_bytes 16

  @doc """
  Reads the persisted owner identity from `owner_id_path`. If the file does not exist, generates a
  new opaque value, writes it once, and returns it. If the file exists but its contents are corrupt
  or empty, fails loud rather than silently generating a replacement — regenerating would orphan any
  claim already made under the original identity, with no local record connecting the two.
  """
  @spec id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def id(owner_id_path) when is_binary(owner_id_path) do
    case File.read(owner_id_path) do
      {:ok, contents} -> validate_or_reject(owner_id_path, contents)
      {:error, :enoent} -> generate_and_persist(owner_id_path)
      {:error, reason} -> {:error, {:corrupt_owner_identity, owner_id_path, reason}}
    end
  end

  defp validate_or_reject(owner_id_path, contents) do
    case String.trim(contents) do
      "" -> {:error, {:corrupt_owner_identity, owner_id_path}}
      value -> {:ok, value}
    end
  end

  defp generate_and_persist(owner_id_path) do
    value = generate()

    with :ok <- File.mkdir_p(Path.dirname(owner_id_path)),
         :ok <- File.write(owner_id_path, value) do
      {:ok, value}
    else
      {:error, reason} -> {:error, {:owner_identity_write_failed, owner_id_path, reason}}
    end
  end

  defp generate do
    @id_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
