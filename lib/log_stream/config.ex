defmodule LogStream.Config do
  @moduledoc false

  def data_dir do
    Application.get_env(:log_stream, :data_dir, "priv/log_stream")
  end

  def flush_interval do
    Application.get_env(:log_stream, :flush_interval, 1_000)
  end

  def max_buffer_size do
    Application.get_env(:log_stream, :max_buffer_size, 1_000)
  end

  def query_timeout do
    Application.get_env(:log_stream, :query_timeout, 30_000)
  end

  @doc false
  # Max age in seconds for retention. nil = keep forever.
  def retention_max_age do
    Application.get_env(:log_stream, :retention_max_age, nil)
  end

  @doc false
  # Max total size in bytes for block storage. nil = unlimited.
  def retention_max_size do
    Application.get_env(:log_stream, :retention_max_size, nil)
  end

  @doc false
  # How often to run retention check, in ms. Default 5 minutes.
  def retention_check_interval do
    Application.get_env(:log_stream, :retention_check_interval, 300_000)
  end
end
