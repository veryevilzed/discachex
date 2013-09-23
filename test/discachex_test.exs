defmodule DiscachexTest do
  use ExUnit.Case

  test "100k records" do
  	{time, :ok} = :timer.tc fn -> 
  		Enum.each 1..100000, fn v -> 
  			Discachex.Storage.set v+100000000, :random.uniform, 7000 
  		end 
  	end
  	IO.puts "Test took #{time}us"
  	receive do after 20000 -> :ok end
  	assert(true)
  end
end
