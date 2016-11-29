defmodule Unit.CompilerCache.BenchTest do
  use ExUnit.Case


  defmodule NeverCompiledCache do
    use CompilerCache, cache_misses: :none

    # callback
    def create_ast(expr) do
      {:ok, ast} = Code.string_to_quoted(expr)
      {ast, []}
    end

  end

  defmodule CompiledCache do
    use CompilerCache, cache_misses: 0

    # callback
    def create_ast(expr) do
      {:ok, ast} = Code.string_to_quoted(expr)
      {ast, []}
    end

  end


  @n 10_000
  @expr "1000 + input"

  test "benchmark " do
    {:ok, _} = NeverCompiledCache.start_link()
    {:ok, _} = CompiledCache.start_link()

    # cache miss #1
    {t1, _} =
      :timer.tc(fn ->
        Enum.each(1..@n, fn(n) ->
          NeverCompiledCache.execute(@expr, n)
        end)
      end)

    CompiledCache.execute(@expr, 1)
    GenServer.call(CompiledCache, :wait_for_completion)

    {t2, _} =
      :timer.tc(fn ->
        Enum.each(1..@n, fn(n) ->
          CompiledCache.execute(@expr, n)
        end)
      end)

    # Make an assumption about the speed improvement
    assert 4 * t2 < t1

    for n <- 1..1_000_000 do
      CompiledCache.execute(@expr, n)
    end

  end

end
