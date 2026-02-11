defmodule LogStream.Index do
  @moduledoc false

  use GenServer

  @default_limit 100
  @default_offset 0

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def index_block(block_meta, entries) do
    GenServer.call(__MODULE__, {:index_block, block_meta, entries})
  end

  def query(filters) do
    GenServer.call(__MODULE__, {:query, filters}, LogStream.Config.query_timeout())
  end

  def delete_blocks_before(cutoff_timestamp) do
    GenServer.call(__MODULE__, {:delete_before, cutoff_timestamp}, 60_000)
  end

  def delete_blocks_over_size(max_bytes) do
    GenServer.call(__MODULE__, {:delete_over_size, max_bytes}, 60_000)
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    db_path = Path.join(data_dir, "index.db")
    {:ok, db} = Exqlite.Sqlite3.open(db_path)
    create_tables(db)
    {:ok, %{db: db}}
  end

  @impl true
  def terminate(_reason, %{db: db}) do
    Exqlite.Sqlite3.close(db)
  end

  @impl true
  def handle_call({:index_block, meta, entries}, _from, state) do
    result = do_index_block(state.db, meta, entries)
    {:reply, result, state}
  end

  def handle_call({:query, filters}, _from, state) do
    result = do_query(state.db, filters)
    {:reply, result, state}
  end

  def handle_call({:delete_before, cutoff}, _from, state) do
    count = do_delete_before(state.db, cutoff)
    {:reply, count, state}
  end

  def handle_call({:delete_over_size, max_bytes}, _from, state) do
    count = do_delete_over_size(state.db, max_bytes)
    {:reply, count, state}
  end

  defp create_tables(db) do
    Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode=WAL")
    Exqlite.Sqlite3.execute(db, "PRAGMA synchronous=NORMAL")

    Exqlite.Sqlite3.execute(db, """
    CREATE TABLE IF NOT EXISTS blocks (
      block_id INTEGER PRIMARY KEY,
      file_path TEXT NOT NULL,
      byte_size INTEGER NOT NULL,
      entry_count INTEGER NOT NULL,
      ts_min INTEGER NOT NULL,
      ts_max INTEGER NOT NULL,
      created_at INTEGER NOT NULL DEFAULT (unixepoch())
    )
    """)

    Exqlite.Sqlite3.execute(db, """
    CREATE TABLE IF NOT EXISTS block_terms (
      term TEXT NOT NULL,
      block_id INTEGER NOT NULL REFERENCES blocks(block_id),
      PRIMARY KEY (term, block_id)
    ) WITHOUT ROWID
    """)

    Exqlite.Sqlite3.execute(db, """
    CREATE INDEX IF NOT EXISTS idx_blocks_ts ON blocks(ts_min, ts_max)
    """)
  end

  defp do_index_block(db, meta, entries) do
    Exqlite.Sqlite3.execute(db, "BEGIN")

    {:ok, block_stmt} =
      Exqlite.Sqlite3.prepare(db, """
      INSERT INTO blocks (block_id, file_path, byte_size, entry_count, ts_min, ts_max)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """)

    Exqlite.Sqlite3.bind(block_stmt, [
      meta.block_id,
      meta.file_path,
      meta.byte_size,
      meta.entry_count,
      meta.ts_min,
      meta.ts_max
    ])

    Exqlite.Sqlite3.step(db, block_stmt)
    Exqlite.Sqlite3.release(db, block_stmt)

    terms = extract_terms(entries)

    {:ok, term_stmt} =
      Exqlite.Sqlite3.prepare(db, """
      INSERT OR IGNORE INTO block_terms (term, block_id) VALUES (?1, ?2)
      """)

    for term <- terms do
      Exqlite.Sqlite3.bind(term_stmt, [term, meta.block_id])
      Exqlite.Sqlite3.step(db, term_stmt)
      Exqlite.Sqlite3.reset(term_stmt)
    end

    Exqlite.Sqlite3.release(db, term_stmt)
    Exqlite.Sqlite3.execute(db, "COMMIT")
    :ok
  end

  defp extract_terms(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      level_term = "level:#{entry.level}"

      metadata_terms =
        Enum.map(entry.metadata, fn {k, v} -> "#{k}:#{v}" end)

      [level_term | metadata_terms]
    end)
    |> Enum.uniq()
  end

  defp do_query(db, filters) do
    start_time = System.monotonic_time()
    {search_filters, pagination} = split_pagination(filters)
    {term_filters, time_filters} = split_filters(search_filters)

    limit = Keyword.get(pagination, :limit, @default_limit)
    offset = Keyword.get(pagination, :offset, @default_offset)
    order = Keyword.get(pagination, :order, :desc)

    block_ids = find_matching_blocks(db, term_filters, time_filters, order)
    blocks_read = length(block_ids)

    all_matching =
      Enum.flat_map(block_ids, fn {_id, file_path} ->
        case LogStream.Writer.read_block(file_path) do
          {:ok, entries} ->
            filtered = filter_entries(entries, search_filters)
            Enum.map(filtered, &LogStream.Entry.from_map/1)

          {:error, reason} ->
            LogStream.Telemetry.event(
              [:log_stream, :block, :error],
              %{},
              %{file_path: file_path, reason: reason}
            )

            []
        end
      end)

    sorted =
      case order do
        :asc -> Enum.sort_by(all_matching, & &1.timestamp, :asc)
        :desc -> Enum.sort_by(all_matching, & &1.timestamp, :desc)
      end

    total = length(sorted)
    page = sorted |> Enum.drop(offset) |> Enum.take(limit)
    duration = System.monotonic_time() - start_time

    LogStream.Telemetry.event(
      [:log_stream, :query, :stop],
      %{duration: duration, total: total, blocks_read: blocks_read},
      %{filters: filters}
    )

    {:ok,
     %LogStream.Result{
       entries: page,
       total: total,
       limit: limit,
       offset: offset
     }}
  end

  defp split_pagination(filters) do
    {pagination, search} =
      Enum.split_with(filters, fn {k, _v} -> k in [:limit, :offset, :order] end)

    {search, pagination}
  end

  defp split_filters(filters) do
    term_filters =
      filters
      |> Enum.filter(fn {k, _v} -> k in [:level, :metadata] end)

    time_filters =
      filters
      |> Enum.filter(fn {k, _v} -> k in [:since, :until] end)

    {term_filters, time_filters}
  end

  defp find_matching_blocks(db, term_filters, time_filters, order) do
    terms = build_query_terms(term_filters)

    {where_clauses, params} = build_where(terms, time_filters)

    order_dir = if order == :asc, do: "ASC", else: "DESC"

    sql =
      if where_clauses == [] do
        "SELECT block_id, file_path FROM blocks ORDER BY ts_min #{order_dir}"
      else
        """
        SELECT DISTINCT b.block_id, b.file_path FROM blocks b
        #{if terms != [], do: "JOIN block_terms bt ON b.block_id = bt.block_id", else: ""}
        WHERE #{Enum.join(where_clauses, " AND ")}
        ORDER BY b.ts_min #{order_dir}
        """
      end

    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)

    if params != [] do
      Exqlite.Sqlite3.bind(stmt, params)
    end

    rows = collect_rows(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    rows
  end

  defp build_query_terms(term_filters) do
    Enum.flat_map(term_filters, fn
      {:level, level} -> ["level:#{level}"]
      {:metadata, map} -> Enum.map(map, fn {k, v} -> "#{k}:#{v}" end)
      _ -> []
    end)
  end

  defp build_where(terms, time_filters) do
    {term_clauses, term_params} =
      case terms do
        [] ->
          {[], []}

        terms ->
          placeholders = Enum.map_join(1..length(terms), ", ", &"?#{&1}")
          {["bt.term IN (#{placeholders})"], terms}
      end

    {time_clauses, time_params} =
      time_filters
      |> Enum.reduce({[], []}, fn
        {:since, ts}, {clauses, params} ->
          idx = length(term_params) + length(params) + 1
          {["b.ts_max >= ?#{idx}" | clauses], params ++ [to_unix(ts)]}

        {:until, ts}, {clauses, params} ->
          idx = length(term_params) + length(params) + 1
          {["b.ts_min <= ?#{idx}" | clauses], params ++ [to_unix(ts)]}
      end)

    {term_clauses ++ time_clauses, term_params ++ time_params}
  end

  defp to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp to_unix(ts) when is_integer(ts), do: ts

  defp filter_entries(entries, filters) do
    Enum.filter(entries, fn entry ->
      Enum.all?(filters, fn
        {:level, level} -> entry.level == level
        {:message, pattern} -> String.contains?(entry.message, pattern)
        {:since, ts} -> entry.timestamp >= to_unix(ts)
        {:until, ts} -> entry.timestamp <= to_unix(ts)

        {:metadata, map} ->
          Enum.all?(map, fn {k, v} ->
            Map.get(entry.metadata, to_string(k)) == to_string(v)
          end)

        _ ->
          true
      end)
    end)
  end

  defp collect_rows(db, stmt) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [block_id, file_path]} -> [{block_id, file_path} | collect_rows(db, stmt)]
      :done -> []
    end
  end

  defp do_delete_before(db, cutoff_timestamp) do
    # Find blocks to delete
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, "SELECT block_id, file_path FROM blocks WHERE ts_max < ?1")

    Exqlite.Sqlite3.bind(stmt, [cutoff_timestamp])
    blocks = collect_rows(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)

    delete_blocks(db, blocks)
  end

  defp do_delete_over_size(db, max_bytes) do
    # Get total size
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT COALESCE(SUM(byte_size), 0) FROM blocks")
    {:row, [total]} = Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)

    if total <= max_bytes do
      0
    else
      # Delete oldest blocks until under budget
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(db, "SELECT block_id, file_path, byte_size FROM blocks ORDER BY ts_min ASC")

      rows = collect_rows_with_size(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)

      {to_delete, _} =
        Enum.reduce_while(rows, {[], total}, fn {block_id, file_path, size}, {acc, remaining} ->
          if remaining > max_bytes do
            {:cont, {[{block_id, file_path} | acc], remaining - size}}
          else
            {:halt, {acc, remaining}}
          end
        end)

      delete_blocks(db, to_delete)
    end
  end

  defp delete_blocks(_db, []), do: 0

  defp delete_blocks(db, blocks) do
    Exqlite.Sqlite3.execute(db, "BEGIN")

    for {block_id, file_path} <- blocks do
      # Delete index entries
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "DELETE FROM block_terms WHERE block_id = ?1")
      Exqlite.Sqlite3.bind(stmt, [block_id])
      Exqlite.Sqlite3.step(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)

      # Delete block record
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "DELETE FROM blocks WHERE block_id = ?1")
      Exqlite.Sqlite3.bind(stmt, [block_id])
      Exqlite.Sqlite3.step(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)

      # Delete block file
      File.rm(file_path)
    end

    Exqlite.Sqlite3.execute(db, "COMMIT")
    length(blocks)
  end

  defp collect_rows_with_size(db, stmt) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [block_id, file_path, size]} ->
        [{block_id, file_path, size} | collect_rows_with_size(db, stmt)]

      :done ->
        []
    end
  end
end
