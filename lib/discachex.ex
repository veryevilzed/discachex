defmodule Discachex do
	use Application.Behaviour

	# See http://elixir-lang.org/docs/stable/Application.Behaviour.html
	# for more information on OTP Applications
	def start(_type, _args) do
		Discachex.Storage.init
		Discachex.Supervisor.start_link
	end
	defmacro set(key, value) do
		quote do
			Discachex.Storage.set(unquote(key), unquote(value))
		end
	end
	defmacro serial_set(key, value) do
		quote do
			Discachex.Storage.serial_set(unquote(key), unquote(value))
		end
	end
	defmacro serial_get(key) do
		quote do
			Discachex.Storage.serial_get(unquote(key))
		end
	end
	defmacro serial_set(key, value, timeout) do
		quote do
			Discachex.Storage.serial_set(unquote(key), unquote(value), unquote(timeout))
		end
	end
	defmacro wait_value(key, value, timeout) do
		quote do
			Discachex.Storage.wait_for_update(unquote(key), unquote(value), unquote(timeout))
		end
	end
	defmacro wait_value(key, value) do
		quote do
			Discachex.Storage.wait_for_update(unquote(key), unquote(value))
		end
	end
	defmacro set(key, value, expiration) do
		quote do 
			Discachex.Storage.set(unquote(key), unquote(value), unquote(expiration))
		end
	end
	defmacro get(key) do
		quote do
			Discachex.Storage.get(unquote(key))
		end
	end
	defmacro dirty_get(key) do
		quote do
			Discachex.Storage.dirty_get(unquote(key))
		end
	end

	defmacro transaction(trx_key, function, time \\ :timer.seconds(600)) do
		quote do
			Discachex.Trx.start_transaction(unquote(trx_key), unquote(function), unquote(time))
		end
	end

	def memo(f, args, time \\ 5000) do
		case get({f, args}) do
			nil -> 
				result = :erlang.apply f, args
				set({f,args}, result, time)
				result
			data -> data
		end
	end
end

defmodule Discachex.Storage do
	require Discachex.Defs

	def init do
		:mnesia.create_table Discachex.Defs.CacheRec, [
			ram_copies: :mnesia.system_info(:db_nodes), 
			type: :ordered_set,
			storage_properties: [ets: [read_concurrency: true]],
			attributes: Discachex.Defs.CacheRec.fields
		]
		:mnesia.add_table_copy Discachex.Defs.CacheRec, :erlang.node, :ram_copies
	end
	
	def timestamp(nil), do: nil
	def timestamp(expiration) do
		{a,b,c} = :erlang.now
		a * 1000*1000 * 1000*1000 + b*1000*1000 + c + expiration*1000
	end

	def notify_waiters(key, value) do
		case :pg2.get_members :discachex_waiters do
			{:error, {:no_such_group, :ok}} -> :ok
			list when length(list) > 0 ->
				lc pid inlist (list |> Enum.uniq), do: send(pid, {:key_updated, key, value})
			_ -> :ok
		end
	end
	def wait_for_update(key, value, timeout \\ 1000) do # waits for value to change...
		:pg2.create :discachex_waiters
		:pg2.join :discachex_waiters, self

		result = :mnesia.activity :transaction, fn ->
			case :mnesia.read Discachex.Defs.CacheRec, key do
				[] -> :no_value
				[Discachex.Defs.CacheRec[value: ^value]|_] -> :old_value
				[Discachex.Defs.CacheRec[value: new_value]|_] -> {:new_value, new_value}
			end
		end
		case result do
			{:new_value, new_value} -> {:key_updated, key, new_value}
			_ ->
				receive do
					{:key_updated, ^key, ^value} -> wait_for_update(key, value, timeout)
					{:key_updated, ^key, new_value} -> {:key_updated, key, new_value}
					{:key_updated, _, _} -> wait_for_update(key, value, timeout)
					after timeout -> :timeout
				end
		end
	end

	def serial_set(key, value, expiration \\ nil) do
		result = :mnesia.activity :transaction, fn ->
			case :mnesia.read Discachex.Defs.CacheRec, key do
				[] -> 
					ts = timestamp(expiration)
					:gen_server.cast Discachex.SerialKiller, {:expire, key, ts}
					:mnesia.write Discachex.Defs.CacheRec[stamp_id: ts, key: key, value: value]
					{:written, value}
				[Discachex.Defs.CacheRec[stamp_id: _time, value: new_value]|_] ->
					{:already_set, new_value}
			end
		end
		case result do
			{:written, value} ->
				notify_waiters(key, value)
			_ -> :ok
		end
		result
	end

	def set(key, value, expiration \\ nil) do
		:mnesia.activity :sync_dirty, fn ->
			ts = timestamp(expiration)
			case :mnesia.read Discachex.Defs.CacheRec, key do
				[] -> 
					:gen_server.cast Discachex.SerialKiller, {:expire, key, ts}
					:mnesia.write Discachex.Defs.CacheRec[stamp_id: ts, key: key, value: value]
				list ->
					lc obj inlist list, do: :mnesia.delete({Discachex.Defs.CacheRec, obj})
					:gen_server.cast Discachex.SerialKiller, {:expire, key, ts}
					:mnesia.write Discachex.Defs.CacheRec[stamp_id: timestamp(expiration), key: key, value: value]
			end
		end
		notify_waiters(key, value)
	end
	def serial_get(key) do
		ts_now = timestamp(0)
		:mnesia.activity :transaction, fn ->
			case :mnesia.read Discachex.Defs.CacheRec, key do
				[Discachex.Defs.CacheRec[stamp_id: time, value: value]] when time > ts_now -> value
				_ -> nil
			end
		end
	end
	def get(key) do
		#
		# not going to report expired records, and not going to panic about their existence...
		#
		ts_now = timestamp(0)
		case :ets.lookup Discachex.Defs.CacheRec, key do
			[Discachex.Defs.CacheRec[stamp_id: time, value: value]] when time > ts_now -> value
			_ -> nil
		end
	end
	def dirty_get(key) do
		#
		# just report what we have now, no matter what it takes...
		#
		case :ets.lookup Discachex.Defs.CacheRec, key do
			[Discachex.Defs.CacheRec[value: value]] -> value
			_ -> nil
		end
	end

	def list_old_keys key, ts_now do
		case :ets.lookup Discachex.Defs.CacheRec, key do
			:'$end_of_table' -> []
			[Discachex.Defs.CacheRec[key: key, stamp_id: stamp]] when stamp < ts_now ->
				[key|list_old_keys :ets.next(Discachex.Defs.CacheRec,key), ts_now]
			[Discachex.Defs.CacheRec[]] -> list_old_keys :ets.next(Discachex.Defs.CacheRec,key), ts_now
			_ -> []
		end
	end
	def list_old_keys do
		ts_now = timestamp 0
		key = :ets.first Discachex.Defs.CacheRec
		list_old_keys key, ts_now
	end
end

defmodule Discachex.SerialKiller do
	use GenServer.Behaviour
	@refresh_timeout :timer.seconds(1)

	def start_link, do: :gen_server.start_link({:local, Discachex.SerialKiller}, Discachex.SerialKiller, [], [])

	defp timestamp() do
		{a,b,c} = :erlang.now
		a * 1000*1000 * 1000*1000 + b*1000*1000 + c
	end

	def init(_) do
		:mnesia.wait_for_tables [Discachex.Defs.CacheRec], :infinity
		keys = :mnesia.dirty_all_keys(Discachex.Defs.CacheRec)
		tree = Enum.reduce keys, :gb_trees.empty, fn key, tree ->
			case :ets.lookup Discachex.Defs.CacheRec, key do
				[Discachex.Defs.CacheRec[stamp_id: stamp]] when is_integer(stamp) ->
					case :gb_trees.is_defined stamp, tree do
						false -> :gb_trees.insert stamp, [key], tree
						true  ->
							prev_value = :gb_trees.get stamp, tree
							:gb_trees.update stamp, [key | prev_value]
					end
				_ -> tree
			end
		end
		{:ok, tree, @refresh_timeout}
	end

	def handle_info(:timeout, tree) do
		case :gb_trees.is_empty tree do
			false ->
				ts_now = timestamp
				{stamp, keys} = :gb_trees.smallest tree
				case stamp < ts_now do
					true ->
						Enum.each(keys, fn key ->
							case :ets.lookup(Discachex.Defs.CacheRec, key) do
								[Discachex.Defs.CacheRec[stamp_id: new_stamp]] when new_stamp < ts_now ->
									:mnesia.dirty_delete Discachex.Defs.CacheRec, key
								_ -> :ok
							end
						end)
						tree = :gb_trees.delete stamp, tree
						{:noreply, tree, @refresh_timeout}
					false ->
						{:noreply, tree, @refresh_timeout}
				end
			true ->
				{:noreply, tree, @refresh_timeout}
		end
	end

	def handle_cast({:expire, key, nil}, tree), do: {:noreply, tree, @refresh_timeout}
	def handle_cast({:expire, key, stamp}, tree) do
		tree = case :gb_trees.is_defined stamp, tree do
			false -> :gb_trees.insert stamp, [key], tree
			true  ->
				prev_value = :gb_trees.get stamp, tree
				:gb_trees.update stamp, [key | prev_value]
		end
		{:noreply, tree, @refresh_timeout}
	end
end

defmodule Discachex.GC do
	use GenServer.Behaviour

	def start_link, do: :gen_server.start_link(Discachex.GC, [], [])

	def init(_opts) do
		:erlang.send_after 1000, self, :cleanup
		{:ok, _opts}
	end

	def handle_info :cleanup, state do
		{time, _} = :timer.tc fn -> 
			Discachex.Storage.list_old_keys 
			|> Enum.each &(:mnesia.dirty_delete Discachex.Defs.CacheRec, &1)
		end
		cond do
			time > 100000 -> IO.puts "Clean-up took #{time}us\r"
			true -> :ok
		end
		:erlang.send_after 1000, self, :cleanup
		{:noreply, state}
	end
end

defmodule Discachex.Trx do
	require Discachex
	def start_transaction(trx_key, processor, ttl) do
		case Discachex.serial_set(trx_key, :processing, ttl) do
			{:already_set, :processing} ->
				case Discachex.wait_value(trx_key, :processing, ttl) do
					{:key_updated, ^trx_key, reply_data} -> reply_data
					:timeout -> :failed
				end
			{:already_set, reply_data} -> reply_data
			{:written, :processing} ->
				result = processor.()
				Discachex.set trx_key, result, ttl
				result
		end
	end
end

defmodule Discachex.Bench do
	def run do
		{time, :ok} = :timer.tc fn -> 
	  		Enum.each 1..100000, fn v -> 
	  			Discachex.Storage.set v+100000000, :random.uniform, 7000 
	  		end 
	  	end
	  	IO.puts "Test took #{time}us"
	  	receive do after 20000 -> :ok end
	end
end
