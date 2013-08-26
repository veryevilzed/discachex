# Discachex

Performance is questionable, but it works well where mnesia works well.


```elixir
iex(18)> :timer.tc fn -> Enum.each 1..100000, fn v -> Discachex.Storage.set v+100000000, :random.uniform, 10000 end end
```


After adding 100k records, like shown above, GC starts working slowly. This behaviour could be optimized if using some better, smarted indexing.


``` 
Clean-up took 10207us
Clean-up took 12738us
Clean-up took 16880us
Clean-up took 21690us
Clean-up took 22878us
{7293488, :ok}
```

As seen above at the end of 7-th second 100k records are written to DB. Let's start waiting for 10 seconds, for DB to clean-up.


```
iex(19)> Clean-up took 21201us
Clean-up took 20546us
Clean-up took 66571us
Clean-up took 174381us <--- garbage collection started here...
Clean-up took 181660us
Clean-up took 191201us
Clean-up took 183309us
Clean-up took 164085us
Clean-up took 148092us <--- garbage collection ended here...
```

And that's it.