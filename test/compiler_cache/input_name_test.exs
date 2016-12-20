defmodule Unit.CompilerCache.InputNameTest do
  use ExUnit.Case

  defmodule ExpressionCache do
    use CompilerCache, input_name: :context

    # callback
    def create_ast(expr) do
      {:ok, ast} = Code.string_to_quoted(expr)
      {ast, []}
    end

  end

  test "compiler cache with 'context' as input name" do
    {:ok, _} = ExpressionCache.start_link()

    # cache miss
    assert 2 = ExpressionCache.execute("1 + context", 1)
    assert 5 = ExpressionCache.execute("1 + context", 4)
  end

end
