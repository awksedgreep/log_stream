defmodule LogStream.MixProject do
  use Mix.Project

  def project do
    [
      app: :log_stream,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Embedded log compression and indexing for Elixir applications.",
      source_url: "https://github.com/awksedgreep/log_stream"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LogStream.Application, []}
    ]
  end

  defp deps do
    [
      {:exqlite, "~> 0.27"},
      {:ezstd, "~> 1.2"}
    ]
  end
end
