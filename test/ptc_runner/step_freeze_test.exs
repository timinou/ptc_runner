defmodule PtcRunner.StepFreezeTest do
  @moduledoc """
  SPELL MOVE-B: `Step.freeze/1` materializes parked-value handles AT THE OWNER.

  A consumer that persists a Step must not hold a `%PtcRunner.Lisp.Handle{}` —
  the HandleStore reaps cold entries, so a later realize races the reaper. The
  runtime owns the store and knows the term is live now, so it freezes the Step
  into self-contained data. An unrealizable handle degrades to a tombstone, not
  a crash.
  """
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp.Handle
  alias PtcRunner.Lisp.HandleStore
  alias PtcRunner.Step

  setup do
    # The store is app-supervised in normal runs; start one here if absent.
    case Process.whereis(HandleStore) do
      nil -> start_supervised!({HandleStore, name: HandleStore})
      _ -> :ok
    end

    :ok
  end

  defp park(term) do
    exec_id = make_ref()
    {HandleStore.put(HandleStore, term, exec_id), exec_id}
  end

  describe "freeze materializes handles into self-contained data" do
    test "a handle in :return is replaced by its realized value" do
      big = %{"items" => Enum.to_list(1..1000)}
      {handle, _} = park(big)
      assert Handle.handle?(handle)

      step = %{Step.ok(handle, %{}) | return: handle}
      frozen = Step.freeze(step)

      refute Handle.handle?(frozen.return)
      assert frozen.return == big
    end

    test "a handle nested in a tool_calls result is materialized" do
      payload = %{"rows" => Enum.to_list(1..500)}
      {handle, _} = park(payload)

      step = %{Step.ok(nil, %{}) | tool_calls: [%{name: "big", args: %{}, result: handle}]}
      frozen = Step.freeze(step)

      [call] = frozen.tool_calls
      refute Handle.handle?(call.result)
      assert call.result == payload
    end

    test "a handle in memory (a def'd parked value) is materialized" do
      val = Enum.to_list(1..2000)
      {handle, _} = park(val)

      step = %{Step.ok(nil, %{"big" => handle}) | memory: %{"big" => handle}}
      frozen = Step.freeze(step)

      refute Handle.handle?(frozen.memory["big"])
      assert frozen.memory["big"] == val
    end

    test "a Step with no handles is returned with identical field values" do
      step = %{Step.ok(42, %{"x" => 1}) | tool_calls: [%{name: "t", args: %{}, result: "ok"}]}
      frozen = Step.freeze(step)

      assert frozen.return == 42
      assert frozen.memory == %{"x" => 1}
      assert frozen.tool_calls == step.tool_calls
    end

    test "nested handle inside a realized value is also frozen (recursive)" do
      inner = %{"deep" => Enum.to_list(1..300)}
      {inner_handle, _} = park(inner)
      # An outer map that itself contains a handle (the realized value nests one).
      outer = %{"a" => 1, "nested" => inner_handle}
      {outer_handle, _} = park(outer)

      step = %{Step.ok(outer_handle, %{}) | return: outer_handle}
      frozen = Step.freeze(step)

      refute Handle.handle?(frozen.return)
      refute Handle.handle?(frozen.return["nested"])
      assert frozen.return["nested"] == inner
    end
  end

  describe "unrealizable handle degrades to a tombstone, never crashes" do
    test "a handle whose term was released freezes to a tombstone marker" do
      {handle, exec_id} = park(%{"x" => Enum.to_list(1..100)})
      # Release the term out from under the handle (simulates eviction/GC).
      HandleStore.release(HandleStore, exec_id)

      step = %{Step.ok(handle, %{}) | return: handle}
      frozen = Step.freeze(step)

      assert Step.unrealized?(frozen.return)
      assert {:__frozen_unrealized__, _reason, meta} = frozen.return
      # The cheap descriptor survives so the dead binding is still inspectable.
      assert is_map(meta)
    end
  end
end
