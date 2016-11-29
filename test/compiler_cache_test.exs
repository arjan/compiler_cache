defmodule Unit.CompilerCacheTest do
  use ExUnit.Case

  defmodule ExpressionCache do
    use CompilerCache

    # callback
    def create_ast(expr) do
      {:ok, ast} = Code.string_to_quoted(expr)
      {ast, []}
    end

  end


  test "Generated accessor functions with default" do
    assert 10_000 == ExpressionCache.max_size
    assert 1 == ExpressionCache.cache_misses
    assert 1000 == ExpressionCache.max_ttl
  end

  test "Override cache options" do
    defmodule MyCache do
      use CompilerCache, max_ttl: 123, max_size: 66, cache_misses: 10

      def create_ast(_expr), do: nil
    end

    assert 66 == MyCache.max_size
    assert 10 == MyCache.cache_misses
    assert 123 == MyCache.max_ttl

  end

  test "compiler cache" do
    {:ok, _} = ExpressionCache.start_link()

    # cache miss
    assert 2 = ExpressionCache.execute("1 + input", 1)
    assert 5 = ExpressionCache.execute("1 + input", 4)
  end

end
