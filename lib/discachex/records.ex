defmodule Discachex.Defs do
	require Record
	Record.defrecord :cacherec, [key: nil, stamp_id: nil, value: nil]
end
