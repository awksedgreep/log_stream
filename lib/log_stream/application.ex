defmodule LogStream.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    data_dir = LogStream.Config.data_dir()
    blocks_dir = Path.join(data_dir, "blocks")
    File.mkdir_p!(blocks_dir)

    children = [
      {LogStream.Index, data_dir: data_dir},
      {LogStream.Buffer, data_dir: data_dir},
      {LogStream.Retention, []}
    ]

    opts = [strategy: :one_for_one, name: LogStream.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
