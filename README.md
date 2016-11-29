# CompilerCache

A generic compilation caching mechanism.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

  1. Add `compiler_cache` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:compiler_cache, "~> 0.1.0"}]
    end
    ```

  2. Ensure `compiler_cache` is started before your application:

    ```elixir
    def application do
      [applications: [:compiler_cache]]
    end
    ```
