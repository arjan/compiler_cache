defmodule Unit.CompilerCache.ContextTest do
  use ExUnit.Case


  defmodule Compiler do
    use CompilerCache, cache_misses: 0

    # callback
    def create_ast(expr) do
      {:ok, ast} = Code.string_to_quoted(expr)
      {ast, [functions: [ {__MODULE__, [square: 1]}]]}
    end

    def square(var) do
      var * var
    end

    def handle_error(e) do
      IO.inspect e
    end

  end

  test "compiler context " do
    {:ok, _} = Compiler.start_link()

    assert 4 = Compiler.execute("square(input)", 2)

    # wait for compilation
    assert %{cache_size: 1} = GenServer.call(Compiler, :wait_for_completion)

    # call compiled version
    assert 4 = Compiler.execute("square(input)", 2)
    assert 4 = Compiler.execute("square(input)", 2)

    :timer.sleep 10
    #assert 25 = Compiler.execute("square(arg)", 5)

  end

end
