defmodule LogStream do
  @moduledoc """
  Embedded log compression and indexing for Elixir applications.

  LogStream plugs into Elixir's Logger as a handler, compresses log entries
  into zstd blocks, and indexes them in SQLite for fast querying.

  ## Setup

      # config/config.exs
      config :log_stream,
        data_dir: "priv/log_stream"

  The handler is installed automatically when the application starts.

  ## Querying

      # Find error logs from the last hour
      LogStream.query(level: :error, since: DateTime.add(DateTime.utc_now(), -3600))

      # Paginated results
      LogStream.query(level: :info, limit: 50, offset: 100, order: :asc)

      # Search log messages with metadata
      LogStream.query(message: "timeout", metadata: %{service: "api"})
  """

  @doc """
  Query stored logs. Returns a `LogStream.Result` struct.

  ## Filters

    * `:level` - Log level atom (`:debug`, `:info`, `:warning`, `:error`)
    * `:message` - Substring match on log message
    * `:since` - DateTime or unix timestamp lower bound
    * `:until` - DateTime or unix timestamp upper bound
    * `:metadata` - Map of metadata key/value pairs to match

  ## Pagination & Ordering

    * `:limit` - Max entries to return (default 100)
    * `:offset` - Number of entries to skip (default 0)
    * `:order` - `:desc` (newest first, default) or `:asc` (oldest first)

  ## Examples

      LogStream.query(level: :error)
      #=> {:ok, %LogStream.Result{entries: [...], total: 42, limit: 100, offset: 0}}

      LogStream.query(level: :warning, limit: 10, offset: 20)
      LogStream.query(message: "connection refused", metadata: %{service: "api"})
  """
  def query(filters \\ []) do
    LogStream.Index.query(filters)
  end

  @doc """
  Flush the buffer, writing any pending log entries to disk immediately.
  """
  def flush do
    LogStream.Buffer.flush()
  end
end
