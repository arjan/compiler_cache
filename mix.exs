defmodule CompilerCache.Mixfile do
  use Mix.Project

  def project do
    [
      app: :compiler_cache,
      version: File.read!("VERSION"),
      elixir: "~> 1.3",
      description: description(),
      package: package(),
      source_url: "https://github.com/arjan/compiler_cache",
      homepage_url: "https://github.com/arjan/compiler_cache",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp description do
    "LRU cache for compiling expressions into functions"
  end

  defp package do
    %{
      files: ["lib", "mix.exs", "*.md", "LICENSE"],
      maintainers: ["Arjan Scherpenisse"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/arjan/compiler_cache"}
    }
  end

  def application do
    [applications: [:logger]]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.12", only: :dev}
    ]
  end
end
