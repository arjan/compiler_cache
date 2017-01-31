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

  ## Example usage

      defmodule MyExpressionParser do
        use CompilerCache

        def create_ast(expression) do
          # Create your AST here based on the expression, e.g.:
          {:ok, ast} = Code.string_to_quoted(expr)
          {ast, []}
        end
      end

  ## Configuration

  In the `use` statement it is possible to give extra compile-time
  options to the compiler cache, like this:

  use CompilerCache, [max_size: 1000, cache_misses: 0]

  The possible options are:

  - `input_name` - The name of the variable that's being used for the
  input to the compiled function. Defaults to `input`.

  - `max_size` - how many entries we can have in the cache table;
  defaults to 10_000.

  - `cache_misses` - after how many cache misses the compiler should
  start compiling the module. Defaults to 1, which means that the
  first expression will not start compilation, but the second hit
  will. When specifying :none, no caching will be done. (for test
  purposes)

  - `max_ttl` - how long entries are allowed to linger in the cache
  (without being called), in seconds. Defaults to 10.


  """

  @ttl_pos 3

  @doc """
  Start the given compiler cache
  """
  @callback start_link() :: GenServer.on_start

  @doc """
  Create the Abstract Syntax Tree and the execution context for the given expression.
  """
  @callback create_ast(expression :: any) :: {ast :: term(), opts :: list(term())}

  use GenServer
  require Logger

  @doc false
  def start_link(mod_def) do
    GenServer.start_link(__MODULE__, mod_def, name: mod_def.module)
  end

  @doc false
  def execute(mod_def, expression, input) do
    key = id(expression)

    # check if we have a ETS table hit
    case :ets.lookup(mod_def.cache_table, key) do
      [] ->  # insert the ETS row
        if increase_hit_count(mod_def, key) do
          # ping the module to compile it when we reach the compilation limit
          GenServer.cast(mod_def.module, {:compile, key, expression})
        end

        try do
          eval_quoted(mod_def, expression, input)
        rescue
          error -> mod_def.module.handle_error(error)
        end

      [{^key, compiled_module, ttl}] ->
        # .. if so; ping the module to register cache hit (LRU)
        GenServer.cast(mod_def.module, {:cache_hit, key, compiled_module, ttl})
        # return fn
        compiled_module.eval(input)

    end
  end

  defp id(expression) do
    :crypto.hash(:sha, :erlang.term_to_binary(expression))
  end

  defp increase_hit_count(mod_def, key) do
    case mod_def.cache_misses do
      :none ->
        false
      cache_misses ->
        case :ets.lookup(mod_def.hit_ctr_table, key) do
          [] ->
            :ets.insert(mod_def.hit_ctr_table, {key, 1})
            cache_misses < 1
          [{^key, ctr}] ->
            :ets.update_element(mod_def.hit_ctr_table, key, {2, ctr+1})
            cache_misses == ctr
        end
    end
  end

  defp eval_quoted(mod_def = %{module: module}, expression, input) do
    try do
      {ast, meta} = module.create_ast(expression)
      {result, _} = Code.eval_quoted(ast, [{mod_def.input_name, input}], meta)
      result
    rescue
      e ->
        module.handle_error(e)
    end
  end

  ##

  defmodule State do
    @moduledoc false
    defstruct def: nil, atom_table: nil, compiling: MapSet.new, waiters: []
  end

  def init(mod_def) do
    Code.compiler_options(ignore_module_conflict: true)

    :ets.new(mod_def.cache_table, [:named_table, :public, {:read_concurrency, true}])
    :ets.new(mod_def.hit_ctr_table, [:named_table, :public, {:write_concurrency, true}, {:read_concurrency, true}])
    :ets.new(mod_def.ttl_table, [:named_table, :public, :ordered_set])

    # Create an atom table and fill it
    atom_table = :ets.new(:compiler_cache_atom_table, [])
    for n <- 1..mod_def.max_size do
      atom = Module.concat(mod_def.module, "Cache#{n}")
      :ets.insert(atom_table, {atom})
    end
    :timer.send_interval(1000, :ttl_check)
    {:ok, %State{def: mod_def, atom_table: atom_table}}
  end

  def handle_cast({:cache_hit, key, mod_name, old_ttl}, state) do
    case :ets.lookup(state.def.ttl_table, old_ttl) do
      [] -> # ignore
        :ok
      [{^old_ttl, _, _}] ->
        ttl = :erlang.monotonic_time

        # update TTL in cache table
        :ets.update_element(state.def.cache_table, key, {@ttl_pos, ttl})

        # remove entry from TTL table
        :ets.delete(state.def.ttl_table, old_ttl)

        # add new entry in TTL table
        :ets.insert(state.def.ttl_table, {ttl, key, mod_name})
    end
    {:noreply, state}
  end

  def handle_cast({:compile, key, expression}, state) do
    if not Enum.member?(state.compiling, key) do
      case get_atom(state) do
        {:ok, mod_name} ->
          parent = self()
          spawn_link(fn ->
            try do
              mod_compile(mod_name, key, expression, state)
            rescue
              _ ->
                # Errors are logged in the synchronous (eval_quoted) flow
                :ok
            after
              send(parent, {:compile_done, key})
            end
          end)
          {:noreply, %State{state | compiling: MapSet.put(state.compiling, key)}}
        {:error, :empty} ->
          {:ok, _, _} = purge(state)
          handle_cast({:compile, key, expression}, state)
      end
    else
      # we are already compiling
      {:noreply, state}
    end
  end

  # used in the tests to let the test process wait for the module to be compiled.
  def handle_call(:wait_for_completion, from, state) do
    if Enum.count(state.compiling) > 0 do
      {:noreply, %{state | waiters: [from | state.waiters]}}
    else
      {:reply, stats(state), state}
    end
  end

  def handle_info(:ttl_check, state) do
    if :ets.info(state.atom_table, :size) == 0 do
      oldest_ttl = :ets.first(state.def.ttl_table)
      purge_loop(oldest_ttl, state)
    end
    {:noreply, state}
  end

  def handle_info({:compile_done, key}, state) do
    state = %State{state | compiling: MapSet.delete(state.compiling, key)}
    if Enum.count(state.compiling) == 0 and Enum.count(state.waiters) > 0 do
      stats = stats(state)
      Enum.map(state.waiters, fn(f) -> GenServer.reply(f, stats) end)
      {:noreply, %State{state | waiters: []}}
    else
      {:noreply, state}
    end
  end

  defp purge_loop(:"$end_of_table", _state), do: :ok
  defp purge_loop(ttl, state) do
    delta = div((:erlang.monotonic_time - ttl), 1_000_000)
    if delta > state.def.max_ttl do
      {:ok, _mod_name, ttl} = purge(ttl, state)
      purge_loop(ttl, state)
    end
  end

  defp stats(state) do
    %{
      slots_remaining: :ets.info(state.atom_table, :size),
      cache_size: :ets.info(state.def.cache_table, :size),
      ttl_size: :ets.info(state.def.ttl_table, :size),
      hit_ctr_size: :ets.info(state.def.hit_ctr_table, :size),
      oldest_ttl: :ets.first(state.def.ttl_table),
      loaded_modules: Enum.count(:code.all_loaded)
    }
  end

  defp context_sort(context) do
    (context[:functions] || []) ++ (context[:macros] || [])
  end

  defp mod_compile(mod_name, key, expression, state) do

    {expression_ast, context} = state.def.module.create_ast(expression)

    imports = context
    |> context_sort()
    |> Enum.map(fn({mod, fns}) ->
      quote do import unquote(mod), only: unquote(fns) end
    end)

    vars = Macro.var(state.def.input_name, nil)
    code = quote do
      unquote_splicing(imports)

      def eval(unquote(vars)) do
        _ = unquote(vars)  # prevent compilation warning about unused variable 'input'
        unquote(expression_ast)
      end
    end


    {:module, ^mod_name, _, _} = Module.create(mod_name, code, [file: "#{inspect(expression)}", line: 1])

    # Remove from hit counter table
    if :ets.lookup(state.def.hit_ctr_table, key) != [] do
      :ets.delete(state.def.hit_ctr_table, key)
    end

    ttl = :erlang.monotonic_time
    # Put it in the cache table
    :ets.insert(state.def.cache_table, {key, mod_name, ttl})
    # And in the TTL table
    :ets.insert(state.def.ttl_table, {ttl, key, mod_name})

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
    oldest_ttl = :ets.first(state.def.ttl_table)
    purge(oldest_ttl, state)
  end

  defp purge(ttl, state) do
    [{_, key, mod_name}] = :ets.lookup(state.def.ttl_table, ttl)
    # Logger.debug "purge: #{mod_name} #{inspect key}"
    :code.purge(mod_name)
    true = :code.delete(mod_name)
    :ets.delete(state.def.ttl_table, ttl)
    :ets.delete(state.def.cache_table, key)
    :ets.insert(state.atom_table, {mod_name})
    next_ttl = :ets.first(state.def.ttl_table)
    {:ok, mod_name, next_ttl}
  end


  @default_input_name :input
  @default_max_size 10000
  @default_cache_misses 1
  @default_max_ttl 1000

  defmacro __using__(opts) do

    quote do
      alias CompilerCache

      @mod_def %{
        module: __MODULE__,
        input_name: unquote(opts[:input_name] || @default_input_name),
        max_size: unquote(opts[:max_size] || @default_max_size),
        cache_misses: unquote(opts[:cache_misses] || @default_cache_misses),
        max_ttl: unquote(opts[:max_ttl] || @default_max_ttl),
        cache_table: unquote(Module.concat(__CALLER__.module, Cache)),
        ttl_table: unquote(Module.concat(__CALLER__.module, TTL)),
        hit_ctr_table: unquote(Module.concat(__CALLER__.module, HitCount))
      }
      def config, do: @mod_def

      @behaviour CompilerCache

      @doc """
      Start your compiler_cache-backed compiler process.
      The cache process is registered under the name of the module.
      """
      def start_link() do
        CompilerCache.start_link(@mod_def)
      end

      def execute(expression, input) do
        CompilerCache.execute(@mod_def, expression, input)
      end

      def stats do
        GenServer.call(__MODULE__, :wait_for_completion, :infinity)
      end

      def handle_error(error) do
        reraise error, System.stacktrace
      end

      defoverridable [handle_error: 1]

    end
  end

end
