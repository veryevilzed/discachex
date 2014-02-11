defmodule DiscachexTest do
  use ExUnit.Case
  require Discachex

  test "Set works" do
    Discachex.Storage.set "testkey", "value"
    assert(Discachex.Storage.get("testkey") == "value")
  end
  test "Expire works" do
    Discachex.Storage.set "testkey2", "value", 1000
    receive do after 1500 -> :ok end
    assert(Discachex.Storage.get("testkey2") == nil)
  end
  test "Dirty reads" do
    Discachex.Storage.set "testkey3", "value", 1000
    assert(Discachex.Storage.dirty_get("testkey3") == "value")
  end
  test "Macros are working" do
    Discachex.set "testkey4", "value"
    assert(Discachex.get("testkey4") == "value")
  end
  test "Memo works" do
    assert(Discachex.memo(&(:random.uniform/1), [100]) == Discachex.memo(&(:random.uniform/1), [100]))
  end
  test "Serial set works" do
    Discachex.serial_set :hello, :world
    assert Discachex.serial_set(:hello, :worldx) == {:already_set, :world} 
  end
  test "Serial set with timeout" do
    Discachex.serial_set :somehello, :world, 500
    :timer.sleep(:timer.seconds(1))
    assert Discachex.get(:somehello) == nil
  end
  test "Messaging works" do
    root = self
    Discachex.set :waitworld, :thevalue, :timer.seconds(5)
    spawn fn -> 
      result = Discachex.wait_value(:waitworld, :thevalue)
      send(root, result)
    end
    Discachex.set :waitworld, :thevalue2
    test_results = receive do
      {:key_updated, :waitworld, :thevalue2} -> :ok
      after 500 -> :error
    end
    assert test_results == :ok
  end
end
