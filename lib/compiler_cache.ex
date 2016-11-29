defmodule CompilerCache do
  @moduledoc """

  A callback-based compilation cache GenServer.

  This genserver caches compiled expressions into a module.

  While expressions are compiling (which can take some time), it
  returns values by calling Code.eval_quoted/3 which is more efficient
  in the short run.

  Internally this uses a fixed pool of atoms as not to exhaust the
  atom table. A LRU cache mechanism is used to clean up unused
  expressions.

  ## Usage

      defmodule MyExpressionParser do
        use CompilerCache

        def create_ast(expression) do
          # Create your AST here based on the expression.
        end

      end


  ## Configuration

  - max_size - how many entries we can have in the cache table;
    defaults to 10_000.

  - cache_misses - after how many cache misses the compiler should
    start compiling the module. Defaults to 2.

  - max_ttl - how long entries are allowed to linger in the cache
    (without being called), in seconds. Defaults to 10.


  """

  @ttl_pos 3

  @callback create_ast(any) :: term()

  use GenServer
  require Logger

  def start_link(module) do
    GenServer.start_link(__MODULE__, module, name: module)
  end

  def execute(module, expression, arg) do
    key = id(expression)

    # check if we have a ETS table hit
    case :ets.lookup(module.cache_table, key) do
    #case [] do
      [{^key, compiled_module, ttl}] ->
        # .. if so; ping the module to register cache hit (LRU)
        GenServer.cast(module, {:cache_hit, key, compiled_module, ttl})
        # return fn
        compiled_module.eval(arg)
      [] ->
        # .. else, ping the module to compile it
        # Logger.warn "miss: #{inspect key}"

        GenServer.cast(module, {:compile, key, expression})

        # ... return the eval_quoted version
        eval_quoted(module, expression, arg)
    end
  end

  defp id(expression), do: :erlang.term_to_binary(expression) |> Base.encode64

  defp eval_quoted(module, expression, arg) do
    {ast, meta} = module.create_ast(expression)
    {result, _} = Code.eval_quoted(ast, [arg: arg], meta)
    result
  end

  ##

  defmodule State do
    defstruct module: nil, atom_table: nil
  end

  def init(module) do
    Code.compiler_options(ignore_module_conflict: true)

    :ets.new(module.cache_table, [:named_table, {:read_concurrency, true}])
    :ets.new(module.ttl_table, [:named_table, :private, :ordered_set])

    # Create an atom table and fill it
    atom_table = :ets.new(:compiler_cache_atom_table, [])
    for n <- 1..module.max_size do
      atom = String.to_atom("CompilerCache.#{module}.#{n}")
      :ets.insert(atom_table, {atom})
    end
    :timer.send_interval(1000, :ttl_check)
    {:ok, %State{module: module, atom_table: atom_table}}
  end

  def handle_cast({:cache_hit, key, mod_name, old_ttl}, state) do
    ttl = :erlang.monotonic_time
    if :ets.update_element(state.module.cache_table, key, {@ttl_pos, ttl}) do
        # remove entry from TTL table;
        :ets.delete(state.module.ttl_table, old_ttl)
        # add new entry in TTL table
        :ets.insert(state.module.ttl_table, {ttl, key, mod_name})
        Logger.warn "hit! #{ttl}"

    else
      :nop
    end
    {:noreply, state}
  end

  def handle_cast({:compile, key, expression}, state) do
    if :ets.lookup(state.module.cache_table, key) == [] do
      case get_atom(state) do
        {:ok, mod_name} ->
          mod_compile(mod_name, key, expression, state)
        {:error, :empty} ->
          mod_name = purge(state)
          handle_cast({:compile, key, expression}, state)
      end
    end
    {:noreply, state}
  end

  # used in the tests to let the test process wait for the module to be compiled.
  def handle_call(:wait_for_completion, _from, state) do
    stats = %{
      slots_remaining: :ets.info(state.atom_table, :size),
      cache_size: :ets.info(state.module.cache_table, :size),
      ttl_size: :ets.info(state.module.ttl_table, :size),
      oldest_ttl: :ets.first(state.module.ttl_table)
    }
    {:reply, stats, state}
  end

  def handle_info(:ttl_check, state) do
    oldest_ttl = :ets.first(state.module.ttl_table)
    purge_loop(oldest_ttl, state)
    {:noreply, state}
  end

  defp purge_loop(:"$end_of_table", state), do: :ok
  defp purge_loop(ttl, state) do
    delta = div((:erlang.monotonic_time - ttl), 1_000_000)
    if delta < state.module.max_ttl do
      {:ok, _mod_name, ttl} = purge(ttl, state)
      purge_loop(ttl, state)
    end
  end

  defp mod_compile(mod_name, key, expression, state) do
    # mod_name = String.to_atom("Compiled." <> key)

    {expression_ast, imports} = state.module.create_ast(expression)
    imports = imports
    |> Enum.map(fn({mod, fns}) ->
      quote do import unquote(mod), only: unquote(fns) end
    end)

    vars = Macro.var(:arg, nil)
    code = quote do
      unquote_splicing(imports)

      def eval(unquote(vars)) do
        _ = unquote(vars)  # prevent compilation warning about unused variable 'variables'
        unquote(expression_ast)
      end
    end

    result = try do
               {:module, ^mod_name, _, _} = Module.create(mod_name, code, [file: IO.inspect(expression), line: 1])
               :ok
             rescue
               error in CompileError ->
                 IO.puts "CompileError! #{inspect error}"
               {:error, error}
             end
    if result == :ok do
      ttl = :erlang.monotonic_time
      # Put it in the cache table
      :ets.insert(state.module.cache_table, {key, mod_name, ttl})
      # And in the TTL table
      :ets.insert(state.module.ttl_table, {ttl, key, mod_name})
    end

    result
  end

  # Get a new atom from the atom table; if there is no room, purge a compiled module.
  defp get_atom(state) do
    case :ets.select(state.atom_table,[{{:"$1"},[],[:"$1"]}],1) do
      {[mod_name], _} ->
        true = :ets.delete(state.atom_table, mod_name)
        {:ok, mod_name}
      :"$end_of_table" ->
        {:ok, mod_name, _ttl} = purge(state)
        true = :ets.delete(state.atom_table, mod_name)
        {:ok, mod_name}
    end
  end

  # Purge the oldest compiled module from the compiler cache.
  # Returns the newly freed mod name and the next oldest TTL
  defp purge(state) do
    oldest_ttl = :ets.first(state.module.ttl_table)
    purge(oldest_ttl, state)
  end

  defp purge(ttl, state) do
    [{_, key, mod_name}] = :ets.lookup(state.module.ttl_table, ttl)
    Logger.warn "purge: #{mod_name} #{inspect key}"
    :code.purge(mod_name)
    true = :code.delete(mod_name)
    :ets.delete(state.module.ttl_table, ttl)
    :ets.delete(state.module.cache_table, key)
    :ets.insert(state.atom_table, {mod_name})
    next_ttl = :ets.first(state.module.ttl_table)
    {:ok, mod_name, next_ttl}
  end


  @default_max_size 10000
  @default_cache_misses 1
  @default_max_ttl 1000

  defmacro __using__(opts) do
    quote do
      alias CompilerCache

      def max_size, do: unquote(opts[:max_size] || @default_max_size)
      def cache_misses, do: unquote(opts[:cache_misses] || @default_cache_misses)
      def max_ttl, do: unquote(opts[:max_ttl] || @default_max_ttl)

      def cache_table, do: unquote(Module.concat(__MODULE__, Cache))
      def ttl_table, do: unquote(Module.concat(__MODULE__, TTL))

      @behaviour CompilerCache

      @doc """
      Start your compiler_cache-backed compiler process.
      The cache process is registered under the name of the module.
      """
      def start_link() do
        CompilerCache.start_link(__MODULE__)
      end

      def execute(expression, arg) do
        CompilerCache.execute(__MODULE__, expression, arg)
      end

    end
  end

end
