defmodule PtcRunner.Lisp.HandleDeepRealizeTest do
  @moduledoc """
  SPELL FEAT-002: `PtcRunner.Lisp.Handle.deep_realize/1` is the single
  handle-realization walker for the runtime. `Step.freeze/1` delegates to it,
  and external consumers (spell Hist's continuation tape) call it directly.

  These tests pin the walker's contract independently of Step.freeze:
    * a bare handle realizes to its term,
    * nested handles in maps/lists/tuples/structs all realize, structure + non-
      handle leaves preserved,
    * an unrealizable (evicted) handle degrades to the canonical tombstone
      `{:__frozen_unrealized__, reason, meta}`, not a crash.
  """
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp.Handle
  alias PtcRunner.Lisp.HandleStore

  setup do
    case Process.whereis(HandleStore) do
      nil -> start_supervised!({HandleStore, name: HandleStore})
      _ -> :ok
    end

    :ok
  end

  # Returns just the handle (callers that don't need to evict).
  defp park(term) do
    HandleStore.put(HandleStore, term, make_ref())
  end

  # Returns {handle, exec_id} so a test can release the term out from under it.
  defp park_evictable(term) do
    exec_id = make_ref()
    {HandleStore.put(HandleStore, term, exec_id), exec_id}
  end

  describe "deep_realize/1" do
    test "a bare handle realizes to its full term" do
      big = %{"items" => Enum.to_list(1..1000)}
      handle = park(big)
      assert Handle.handle?(handle)

      assert Handle.deep_realize(handle) == big
    end

    test "handles nested in a map are realized; non-handle leaves preserved" do
      payload = %{"rows" => [1, 2, 3]}
      handle = park(payload)

      input = %{"a" => handle, "b" => 42, "c" => "literal"}
      out = Handle.deep_realize(input)

      assert out["a"] == payload
      assert out["b"] == 42
      assert out["c"] == "literal"
    end

    test "handles nested in lists and tuples are realized, structure intact" do
      h1 = park(%{"x" => 1})
      h2 = park([:a, :b])

      input = [h1, {h2, "tail"}, :plain]
      out = Handle.deep_realize(input)

      assert out == [%{"x" => 1}, {[:a, :b], "tail"}, :plain]
    end

    test "handles in a struct's public fields are realized, struct type preserved" do
      handle = park(%{"deep" => true})
      # Use an arbitrary struct with a handle-bearing field.
      input = %PtcRunner.Turn{number: 1, result: handle, memory: %{}}

      out = Handle.deep_realize(input)

      assert %PtcRunner.Turn{} = out
      assert out.result == %{"deep" => true}
      assert out.number == 1
    end

    test "a recursively-parked handle (handle whose term holds a handle) fully realizes" do
      inner = park(%{"leaf" => 7})
      outer = park(%{"wrap" => inner})

      assert Handle.deep_realize(outer) == %{"wrap" => %{"leaf" => 7}}
    end

    test "an evicted handle degrades to a tombstone, not a crash" do
      {handle, exec_id} = park_evictable(%{"gone" => true})
      # Release the term out from under the walker (simulates the reaper).
      HandleStore.release(HandleStore, exec_id)

      out = Handle.deep_realize(handle)

      assert Handle.unrealized?(out)
      assert {:__frozen_unrealized__, _reason, _meta} = out
    end

    test "non-handle terms pass through unchanged (identity on plain data)" do
      term = %{"a" => [1, 2, {:x, "y"}], "b" => nil}
      assert Handle.deep_realize(term) == term
    end

    test "unrealized?/1 rejects ordinary values" do
      refute Handle.unrealized?(%{"a" => 1})
      refute Handle.unrealized?(nil)
      refute Handle.unrealized?({:ok, 1})
    end
  end
end
