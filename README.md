# LogStream

Embedded log compression and indexing for Elixir applications. Add one dependency, configure a data directory, and your app gets compressed, searchable logs with zero external infrastructure.

Logs are compressed with zstd (~10x compression ratio) and indexed in SQLite for fast querying.

## Installation

```elixir
def deps do
  [
    {:log_stream, "~> 0.1"}
  ]
end
```

## Setup

```elixir
# config/config.exs
config :log_stream,
  data_dir: "priv/log_stream"
```

That's it. LogStream installs itself as a `:logger` handler on application start. All `Logger` calls are automatically captured, compressed, and indexed.

## Querying

```elixir
# Recent errors
LogStream.query(level: :error, since: DateTime.add(DateTime.utc_now(), -3600))

# Search by metadata
LogStream.query(level: :info, metadata: %{request_id: "abc123"})

# Substring match on message
LogStream.query(message: "timeout")

# Pagination
LogStream.query(level: :warning, limit: 50, offset: 100, order: :asc)
```

Returns a `LogStream.Result` struct:

```elixir
{:ok, %LogStream.Result{
  entries: [%LogStream.Entry{timestamp: ..., level: :error, message: "...", metadata: %{}}],
  total: 42,
  limit: 100,
  offset: 0
}}
```

## Retention

Configure automatic cleanup to prevent unbounded disk growth:

```elixir
config :log_stream,
  data_dir: "priv/log_stream",
  retention_max_age: 7 * 24 * 3600,       # Delete logs older than 7 days
  retention_max_size: 100 * 1024 * 1024,   # Keep total blocks under 100 MB
  retention_check_interval: 300_000         # Check every 5 minutes (default)
```

You can also trigger cleanup manually:

```elixir
LogStream.Retention.run_now()
```

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `data_dir` | `"priv/log_stream"` | Root directory for blocks and index |
| `flush_interval` | `1_000` | Buffer flush interval in ms |
| `max_buffer_size` | `1_000` | Max entries before auto-flush |
| `query_timeout` | `30_000` | Query timeout in ms |
| `retention_max_age` | `nil` | Max log age in seconds (`nil` = keep forever) |
| `retention_max_size` | `nil` | Max block storage in bytes (`nil` = unlimited) |
| `retention_check_interval` | `300_000` | Retention check interval in ms |

## Telemetry

LogStream emits telemetry events for monitoring:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:log_stream, :flush, :stop]` | `duration`, `entry_count`, `byte_size` | `block_id` |
| `[:log_stream, :query, :stop]` | `duration`, `total`, `blocks_read` | `filters` |
| `[:log_stream, :retention, :stop]` | `duration`, `blocks_deleted` | |
| `[:log_stream, :block, :error]` | | `file_path`, `reason` |

## Benchmarks

On a simulated week of Phoenix logs (~1.1M entries, ~30 req/min):

| Metric | Value |
|--------|-------|
| Compression ratio | 10.3x |
| Raw size | 246 MB |
| Compressed size | 24 MB |
| Index size | 31 MB |
| Total disk | 55 MB |
| Ingestion throughput | 335K entries/sec |

Query latency (1.1M entries indexed):

| Query | Median |
|-------|--------|
| Specific request_id | 1.1ms |
| Last 1h + level=error | 3.4ms |
| Last 1 hour (all levels) | 6.6ms |
| level=error (all time) | 560ms |
| Message substring search | 820ms |

## How It Works

1. Your app logs normally via `Logger`
2. LogStream captures log events via an OTP `:logger` handler
3. Events buffer in a GenServer, flushing every 1s or 1000 entries
4. Each flush compresses the batch with zstd and writes a `.zst` block file
5. Block metadata and an inverted index of terms are stored in SQLite (WAL mode)
6. Queries hit the SQLite index to find relevant blocks, decompress only those, and filter entries

## License

MIT - see [LICENSE](LICENSE) for details.
