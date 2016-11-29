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

  @module_pos 2
  @ttl_pos 3

  @callback create_ast(any) :: term()

  use GenServer
  require Logger

  def start_link(module) do
    GenServer.start_link(__MODULE__, module, name: module)
  end

  def execute(module, expression, input) do
    key = id(expression)

    # check if we have a ETS table hit
    case :ets.lookup(module.cache_table, key) do
      [] ->
      # insert the ETS row
      if increase_hit_count(module, key) do
        # ping the module to compile it
        GenServer.cast(module, {:compile, key, expression})
      end
        try do
          eval_quoted(module, expression, input)
        rescue
          error -> module.handle_error(error)
        end

      [{^key, compiled_module, ttl}] ->
        # .. if so; ping the module to register cache hit (LRU)
        GenServer.cast(module, {:cache_hit, key, compiled_module, ttl})
        # return fn
        compiled_module.eval(input)

    end
  end

  defp id(expression) do
    :crypto.hash(:sha, :erlang.term_to_binary(expression))
  end

  defp increase_hit_count(module, key) do
    cond do
      module.cache_misses == :none ->
        false
      module.cache_misses < 1 ->
        true
      true ->
        hit_count = case :ets.lookup(module.hit_ctr_table, key) do
                      [] ->
                        :ets.insert(module.hit_ctr_table, {key, 1})
                        1
                      [{^key, ctr}] ->
                        :ets.update_element(module.hit_ctr_table, key, {2, ctr+1})
                        ctr + 1
                    end
        module.cache_misses <= hit_count
    end
  end

  defp eval_quoted(module, expression, input) do
    try do
      {ast, meta} = module.create_ast(expression)
      {result, _} = Code.eval_quoted(ast, [input: input], meta)
      result
    rescue
      e ->
        module.handle_error(e)
    end
  end

  ##

  defmodule State do
    defstruct module: nil, atom_table: nil
  end

  def init(module) do
    Code.compiler_options(ignore_module_conflict: true)

    :ets.new(module.cache_table, [:named_table, {:read_concurrency, true}])
    :ets.new(module.hit_ctr_table, [:named_table, :public, {:write_concurrency, true}, {:read_concurrency, true}])
    :ets.new(module.ttl_table, [:named_table, :private, :ordered_set])

    # Create an atom table and fill it
    atom_table = :ets.new(:compiler_cache_atom_table, [])
    for n <- 1..module.max_size do
      atom = Module.concat(module, "Cache#{n}")
      :ets.insert(atom_table, {atom})
    end
    :timer.send_interval(1000, :ttl_check)
    {:ok, %State{module: module, atom_table: atom_table}}
  end

  def handle_cast({:cache_hit, key, mod_name, old_ttl}, state) do
    case :ets.lookup(state.module.ttl_table, old_ttl) do
      [] -> # ignore
        :ok
      [{^old_ttl, _, _}] ->
        ttl = :erlang.monotonic_time

        # update TTL in cache table
        :ets.update_element(state.module.cache_table, key, {@ttl_pos, ttl})

        # remove entry from TTL table
        :ets.delete(state.module.ttl_table, old_ttl)

        # add new entry in TTL table
        :ets.insert(state.module.ttl_table, {ttl, key, mod_name})
    end
    {:noreply, state}
  end

  def handle_cast({:compile, key, expression}, state) do
    if :ets.lookup(state.module.cache_table, key) == [] do
      case get_atom(state) do
        {:ok, mod_name} ->
          try do
            mod_compile(mod_name, key, expression, state)
          rescue
            _ ->
              # Errors are logged in the synchronous (eval_quoted) flow
              :ok
          end
        {:error, :empty} ->
          {:ok, _, _} = purge(state)
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
      hit_ctr_size: :ets.info(state.module.hit_ctr_table, :size),
      oldest_ttl: :ets.first(state.module.ttl_table),
      loaded_modules: Enum.count(:code.all_loaded)
    }
    {:reply, stats, state}
  end

  def handle_info(:ttl_check, state) do
    oldest_ttl = :ets.first(state.module.ttl_table)
    purge_loop(oldest_ttl, state)
    {:noreply, state}
  end

  defp purge_loop(:"$end_of_table", _state), do: :ok
  defp purge_loop(ttl, state) do
    delta = div((:erlang.monotonic_time - ttl), 1_000_000)
    if delta > state.module.max_ttl do
      {:ok, _mod_name, ttl} = purge(ttl, state)
      purge_loop(ttl, state)
    end
  end

  defp context_sort(context) do
    (context[:functions] || []) ++ (context[:macros] || [])
  end

  defp mod_compile(mod_name, key, expression, state) do
    # mod_name = String.to_atom("Compiled." <> key)

    {expression_ast, context} = state.module.create_ast(expression)

    imports = context
    |> context_sort()
    |> Enum.map(fn({mod, fns}) ->
      quote do import unquote(mod), only: unquote(fns) end
    end)

    vars = Macro.var(:input, nil)
    code = quote do
      unquote_splicing(imports)

      def eval(unquote(vars)) do
        _ = unquote(vars)  # prevent compilation warning about unused variable 'input'
        unquote(expression_ast)
      end
    end

    {:module, ^mod_name, _, _} = Module.create(mod_name, code, [file: "#{inspect(expression)}", line: 1])

    # Remove from hit counter table
    if :ets.lookup(state.module.hit_ctr_table, key) != [] do
      :ets.delete(state.module.hit_ctr_table, key)
    end

    ttl = :erlang.monotonic_time
    # Put it in the cache table
    :ets.insert(state.module.cache_table, {key, mod_name, ttl})
    # And in the TTL table
    :ets.insert(state.module.ttl_table, {ttl, key, mod_name})

    :ok
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
    # Logger.debug "purge: #{mod_name} #{inspect key}"
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

      def cache_table, do: unquote(Module.concat(__CALLER__.module, Cache))
      def ttl_table, do: unquote(Module.concat(__CALLER__.module, TTL))
      def hit_ctr_table, do: unquote(Module.concat(__CALLER__.module, HitCount))

      @behaviour CompilerCache

      @doc """
      Start your compiler_cache-backed compiler process.
      The cache process is registered under the name of the module.
      """
      def start_link() do
        CompilerCache.start_link(__MODULE__)
      end

      def execute(expression, input) do
        CompilerCache.execute(__MODULE__, expression, input)
      end

      def handle_error(error) do
        reraise error, System.stacktrace
      end

      defoverridable [handle_error: 1]

    end
  end

end
