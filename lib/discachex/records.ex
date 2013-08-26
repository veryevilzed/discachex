defmodule Discachex.Defs do
	defrecord CacheRec, [stamp_id: nil, key: nil, value: nil] do
		def fields do lc {name, _} inlist @record_fields, do: name end
	end
end
