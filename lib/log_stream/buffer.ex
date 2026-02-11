defmodule LogStream.Buffer do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def log(entry) do
    GenServer.cast(__MODULE__, {:log, entry})
  end

  def flush do
    GenServer.call(__MODULE__, :flush, LogStream.Config.query_timeout())
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    interval = LogStream.Config.flush_interval()
    schedule_flush(interval)

    :logger.add_handler(LogStream.Handler.handler_id(), LogStream.Handler, %{level: :all})

    {:ok, %{buffer: [], data_dir: data_dir, flush_interval: interval}}
  end

  @impl true
  def terminate(_reason, state) do
    :logger.remove_handler(LogStream.Handler.handler_id())
    do_flush(state.buffer, state.data_dir)
    :ok
  end

  @impl true
  def handle_cast({:log, entry}, state) do
    buffer = [entry | state.buffer]

    if length(buffer) >= LogStream.Config.max_buffer_size() do
      do_flush(buffer, state.data_dir)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: buffer}}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    do_flush(state.buffer, state.data_dir)
    {:reply, :ok, %{state | buffer: []}}
  end

  @impl true
  def handle_info(:flush_timer, state) do
    if state.buffer != [] do
      do_flush(state.buffer, state.data_dir)
    end

    schedule_flush(state.flush_interval)
    {:noreply, %{state | buffer: []}}
  end

  defp do_flush([], _data_dir), do: :ok

  defp do_flush(buffer, data_dir) do
    entries = Enum.reverse(buffer)
    start_time = System.monotonic_time()

    case LogStream.Writer.write_block(entries, data_dir) do
      {:ok, block_meta} ->
        LogStream.Index.index_block(block_meta, entries)
        duration = System.monotonic_time() - start_time

        LogStream.Telemetry.event(
          [:log_stream, :flush, :stop],
          %{duration: duration, entry_count: block_meta.entry_count, byte_size: block_meta.byte_size},
          %{block_id: block_meta.block_id}
        )

      {:error, reason} ->
        IO.warn("LogStream: failed to write block: #{inspect(reason)}")
    end
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush_timer, interval)
  end
end
