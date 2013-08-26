defmodule Discachex do
  use Application.Behaviour

  # See http://elixir-lang.org/docs/stable/Application.Behaviour.html
  # for more information on OTP Applications
  def start(_type, _args) do
  	Discachex.Storage.init
    Discachex.Supervisor.start_link
  end
end

defmodule Discachex.Storage do
	require Discachex.Defs

	def init do
		:mnesia.create_table Discachex.Defs.CacheRec, [
			ram_copies: [:erlang.node|:erlang.nodes], 
			attributes: Discachex.Defs.CacheRec.fields, 
			index: [:key]
		]
	end
	
	def timestamp(nil), do: nil
	def timestamp(expiration) do
		{a,b,c} = :erlang.now
		a * 1000*1000 * 1000*1000 + b*1000*1000 + c + expiration*1000
	end

	def set(key, value, expiration // nil) do
		:mnesia.activity :transaction, fn ->
			case :mnesia.match_object Discachex.Defs.CacheRec[key: key, _: :_] do
				[] -> 
					:mnesia.write Discachex.Defs.CacheRec[stamp_id: {timestamp(expiration), key}, key: key, value: value]
				list ->
					lc obj inlist list, do: :mnesia.delete_object(obj)

					:mnesia.write Discachex.Defs.CacheRec[stamp_id: {timestamp(expiration), key}, key: key, value: value]
			end
		end
	end
	def get(key) do
		#
		# not going to report expired records, and not going to panic about their existence...
		#
		ts_now = timestamp(0)
		case :mnesia.dirty_match_object Discachex.Defs.CacheRec[key: key, _: :_] do
			[Discachex.Defs.CacheRec[stamp_id: {time, _}, value: value]] when time > ts_now -> value
			_ -> nil
		end
	end
	def dirty_get(key) do
		#
		# just report what we have now, no matter what it takes...
		#
		case :mnesia.dirty_match_object Discachex.Defs.CacheRec[key: key, _: :_] do
			[Discachex.Defs.CacheRec[value: value]] -> value
			_ -> nil
		end
	end

	def list_old_keys do
		ts_now = timestamp 0
		:mnesia.activity(:sync_dirty, fn -> 
			:mnesia.select(Discachex.Defs.CacheRec, ( 
				[{Discachex.Defs.CacheRec[stamp_id: {:"$1", :_}, key: :_, value: :_], [{:<, :"$1", ts_now}], [:"$_"]}]
			)) 
			|> Enum.each(fn (obj) -> :mnesia.delete_object(obj) end)
		end)
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
		{time, _} = :timer.tc fn -> Discachex.Storage.list_old_keys end
		cond do
			time > 10000 -> IO.puts "Clean-up took #{time}us\r"
			true -> :ok
		end
		:erlang.send_after 1000, self, :cleanup
		{:noreply, state}
	end
end