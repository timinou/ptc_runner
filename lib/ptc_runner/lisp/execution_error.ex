defmodule PtcRunner.Lisp.ExecutionError do
  @moduledoc """
  Exception used to signal execution errors during Lisp evaluation.

  This exception is used internally by the `tool_executor` and `ToolNormalizer`
  to propagate structured errors (like unknown tools or tool failures)
  out of the evaluation loop and into the `Step` failure result.
  """
  # `:tool_name` (BUG-462 follow-up): a :tool_error carries an ACTIONABLE
  # `message` ("tool 'X' failed: why") so a program's `(catch e ...)` sees the
  # reason via `Exception.message/1`. But the legacy `{:tool_error, name,
  # reason}` tuple that `Lisp.format_error/1` renders reads slot-2 as the bare
  # NAME — so the name must travel separately, else the formatter wraps the rich
  # message a second time ("Tool 'tool 'X' failed: why' failed: ..."). Keep the
  # bare name here; keep the rich text in `message`.
  defexception [:reason, :message, :data, :tool_name, :child_trace_id, :child_step]

  @doc """
  Compile-time list of stable parallel error reasons that must survive
  nesting unchanged so the security/capacity outcome is deterministic at
  any depth. Safe to use in guard clauses.
  """
  defmacro stable_parallel_reasons do
    [:memory_exceeded, :timeout, :parallel_capacity_exceeded]
  end
end
