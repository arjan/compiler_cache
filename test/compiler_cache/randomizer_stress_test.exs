defmodule Unit.CompilerCache.RandomizerStressTest do
  use ExUnit.Case


  defmodule ExpressionCache do
    use CompilerCache

    # callback
    def create_ast(expr) do
      {:ok, ast} = Code.string_to_quoted(expr)
      {ast, []}
    end

  end

  @n 100_000
  @m 100

  test "small stresstest" do
    {:ok, _} = ExpressionCache.start_link()

    1..@m
    |> Enum.map(fn(_) ->
      Task.async(fn ->
        for _ <- 1..@n do
          a = random()
          b = random()
          assert a * b == ExpressionCache.execute(expression(a), b)
        end
      end)
    end)
    |> Task.yield_many

    stats = ExpressionCache.stats
    IO.puts "stats: #{inspect stats}"


  end

  defp expression(num) do
    "#{num} * input"
  end

  defp random, do: Enum.random(1..100)

end
