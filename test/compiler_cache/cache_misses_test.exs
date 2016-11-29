defmodule Unit.CompilerCache.CacheMissesTest do
  use ExUnit.Case

  defmodule ExpressionCache do
    use CompilerCache, min_ttl: 10, cache_misses: 2, max_size: 10

    # callback
    def create_ast(expr) do
      {:ok, ast} = Code.string_to_quoted(expr)
      {ast, []}
    end

  end


  test "compile an expression after 2 cache misses" do
    {:ok, _} = ExpressionCache.start_link()

    # cache miss #1
    assert 2 = ExpressionCache.execute("1 + input", 1)

    info = GenServer.call(ExpressionCache, :wait_for_completion)
    assert 10 == info.slots_remaining
    assert 0 == info.cache_size
    assert 1 == info.hit_ctr_size

    # cache miss #2
    assert 6 = ExpressionCache.execute("1 + input", 5)

    info = GenServer.call(ExpressionCache, :wait_for_completion)
    assert 10 == info.slots_remaining
    assert 0 == info.cache_size
    assert 1 == info.hit_ctr_size

    # cache miss #3; will compile
    assert 6 = ExpressionCache.execute("1 + input", 5)

    info = GenServer.call(ExpressionCache, :wait_for_completion)
    # but now it has compiled the expression
    assert 9 == info.slots_remaining
    assert 1 == info.cache_size
    assert 0 == info.hit_ctr_size

  end

  defmodule DefaultExpressionCache do
    use CompilerCache

    # callback
    def create_ast(expr) do
      {:ok, ast} = Code.string_to_quoted(expr)
      {ast, []}
    end

  end

  test "compile an expression after 1 cache miss" do
    {:ok, _} = DefaultExpressionCache.start_link()

    # cache miss #1
    assert 2 = DefaultExpressionCache.execute("1 + input", 1)

    info = GenServer.call(DefaultExpressionCache, :wait_for_completion)
    assert 10000 == info.slots_remaining
    assert 0 == info.cache_size
    assert 1 == info.hit_ctr_size

    assert 2 = DefaultExpressionCache.execute("1 + input", 1)

    info = GenServer.call(DefaultExpressionCache, :wait_for_completion)
    assert 9999 == info.slots_remaining
    assert 1 == info.cache_size
    assert 0 == info.hit_ctr_size

  end

end
