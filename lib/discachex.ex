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

	def memo(f, args, time // 5000) do
		case get({f, args}) do
			nil -> 
				result = :erlang.apply f, args
				set({f,args}, result, 5000)
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

	def set(key, value, expiration // nil) do
		:mnesia.activity :sync_dirty, fn ->
			case :mnesia.read Discachex.Defs.CacheRec, key do
				[] -> 
					:mnesia.write Discachex.Defs.CacheRec[stamp_id: timestamp(expiration), key: key, value: value]
				list ->
					lc obj inlist list, do: :mnesia.delete({Discachex.Defs.CacheRec, obj})

					:mnesia.write Discachex.Defs.CacheRec[stamp_id: timestamp(expiration), key: key, value: value]
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
