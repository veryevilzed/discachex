defmodule Discachex.Mixfile do
  use Mix.Project

  def project do
    [ app: :discachex,
      version: "0.0.1",
      deps: deps ]
  end

  def application do
    [
      mod: { Discachex, [] },
      applications: [:mnesia]
    ]
  end

  defp deps do
    []
  end
end
