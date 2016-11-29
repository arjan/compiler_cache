defmodule Unit.CompilerCache.TTLTest do
  use ExUnit.Case

  defmodule ExpressionCache do
    use CompilerCache, min_ttl: 10, cache_misses: 0, max_size: 10

    # callback
    def create_ast(expr) do
      {:ok, ast} = Code.string_to_quoted(expr)
      {ast, []}
    end

  end


  test "immediately compile an expression" do
    {:ok, _} = ExpressionCache.start_link()

    assert 0 == :ets.info(ExpressionCache.cache_table, :size)
    # assert 0 == :ets.info(ExpressionCache.ttl_table, :size)

    # cache miss
    assert 2 = ExpressionCache.execute("1 + input", 1)

    # it's compiling
    info = GenServer.call(ExpressionCache, :wait_for_completion)
    assert 9 == info.slots_remaining
    assert 1 == info.cache_size

    # compile another one
    assert 8 = ExpressionCache.execute("2 * input", 4)

    info = GenServer.call(ExpressionCache, :wait_for_completion)
    assert 8 == info.slots_remaining
    assert 2 == info.cache_size
    assert 2 == info.ttl_size

    # cache hit
    assert 2 = ExpressionCache.execute("2 * input", 1)

    # stats stay the same
    info = GenServer.call(ExpressionCache, :wait_for_completion)
    assert 8 == info.slots_remaining
    assert 2 == info.cache_size
    assert 2 == info.ttl_size

  end

  test "test expire oldest expressions" do
    {:ok, _} = ExpressionCache.start_link()

    assert 0 == :ets.info(ExpressionCache.ttl_table, :size)

    # Create 10 expressions; filling the cache table
    for n <- 1..10 do
      ExpressionCache.execute("#{n}", 1)
    end

    info = GenServer.call(ExpressionCache, :wait_for_completion)
    assert 0 == info.slots_remaining
    assert 10 == info.cache_size
    oldest_ttl = info.oldest_ttl

    # Now when we compile a new expression, the oldest one should be gone from the TTL cache.
    assert 3 == ExpressionCache.execute("1 + 2", 1)
    info = GenServer.call(ExpressionCache, :wait_for_completion)

    assert 0 == info.slots_remaining
    assert 10 == info.cache_size
    assert oldest_ttl < info.oldest_ttl

    prev_loaded_modules = info.loaded_modules

    # wait 2 seconds until purge has finished
    :timer.sleep(1000)

    info = GenServer.call(ExpressionCache, :wait_for_completion)

    assert 10 == info.slots_remaining
    assert 0 == info.cache_size

    # there should have been some cleanup taken place
    assert info.loaded_modules < prev_loaded_modules

  end

end
