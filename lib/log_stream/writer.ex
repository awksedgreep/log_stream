defmodule LogStream.Writer do
  @moduledoc false

  require Logger

  def write_block(entries, data_dir) do
    binary = :erlang.term_to_binary(entries)
    compressed = :ezstd.compress(binary)
    block_id = System.unique_integer([:positive, :monotonic])
    filename = "#{String.pad_leading(Integer.to_string(block_id), 12, "0")}.zst"
    file_path = Path.join([data_dir, "blocks", filename])

    case File.write(file_path, compressed) do
      :ok ->
        timestamps = Enum.map(entries, & &1.timestamp)

        meta = %{
          block_id: block_id,
          file_path: file_path,
          byte_size: byte_size(compressed),
          entry_count: length(entries),
          ts_min: Enum.min(timestamps),
          ts_max: Enum.max(timestamps)
        }

        {:ok, meta}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read_block(file_path) do
    case File.read(file_path) do
      {:ok, compressed} ->
        try do
          binary = :ezstd.decompress(compressed)
          {:ok, :erlang.binary_to_term(binary)}
        rescue
          e ->
            Logger.warning("LogStream: corrupt block #{file_path}: #{inspect(e)}")
            {:error, :corrupt_block}
        end

      {:error, reason} ->
        Logger.warning("LogStream: cannot read block #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
