defmodule Discachex.Defs do
	defrecord CacheRec, [key: nil, stamp_id: nil, value: nil] do
		def fields do lc {name, _} inlist @record_fields, do: name end
	end
end
