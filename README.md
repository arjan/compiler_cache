# CompilerCache

LRU cache for compiling expressions into functions.

Using `CompilerCache`, it is easy to create custom expressions that perform well.

Instead of relying on using `Code.eval_quoted`, the CompilerCache
system compiles given ASTs into modules.

The compilation cache has a fixed maximum size, and uses a fixed pool
of module names as not to exhaust the BEAM vm's atom table.

Creating a compilation cache is as simple as `use CompilerCache` and
implementing the `create_ast/1` function:

```elixir
defmodule ExpressionCache do
  use CompilerCache
  def create_ast(expr) do
    {:ok, ast} = Code.string_to_quoted(expr)
    {ast, []}
  end
end
```

The `create_ast/2` function must return an `{ast, opts}` tuple. The opts are the same as those given to [Code.eval_quoted/3](https://github.com/elixir-lang/elixir/blob/v1.3.4/lib/elixir/lib/code.ex#L191).

This cache can then be called like this:

```elixir
{:ok, _} = ExpressionCache.start_link()
iex> ExpressionCache.execute("1 + 1", nil)
2
iex> ExpressionCache.execute("2 * input", 3)
6
```

After *N* cache misses (default: 2), expressions are cached into a
module on the background by the compiler process. This speeds up
consecutive executions considerable (~10x speedups are not unheard
of).



## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

  1. Add `compiler_cache` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:compiler_cache, "~> 1.0"}]
    end
    ```

  2. Ensure `compiler_cache` is started before your application:

    ```elixir
    def application do
      [applications: [:compiler_cache]]
    end
    ```
