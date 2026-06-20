defmodule PtcRunner.Lisp.StepFormTest do
  @moduledoc """
  SPELL MOVE-C: `Step.form` — the executed CoreAST emitted as structured data.

  `Step.program`/`memory`/`return` are strings and data; `Step.form` is the
  PROGRAM AS DATA — the canonical CoreAST the runtime parsed and ran. A consumer
  (SpellAgent.Hist lenses) can walk that tree (defs, tool calls, structure)
  instead of re-parsing the `program` string, which only ever worked when
  something already held the tuple form.

  The load-bearing test is the AST-DRIFT CONTRACT: `Step.form` MUST equal what a
  consumer would get by independently parsing+analyzing the same source. If a
  future ptc_runner changes its AST shape, this test fails loudly at the seam
  rather than silently corrupting recorded lenses.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.CoreToSource
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Step

  describe "Step.form carries the executed CoreAST" do
    test "a simple program's form is the analyzed AST, not the string" do
      src = "(+ 1 2)"
      assert {:ok, %Step{form: form, return: 3}} = Lisp.run(src)

      refute is_binary(form)
      {:ok, raw} = Parser.parse(src)
      {:ok, expected} = Analyze.analyze(raw)
      assert form == expected
    end

    test "a def program's form exposes the {:def, ...} node for structural walks" do
      assert {:ok, %Step{form: form}} = Lisp.run("(def x 7)")
      # The canonical def shape — a lens can match this without re-parsing. The
      # name is a BINARY (0.12 keeps user def names un-atomized for atom-table
      # safety), the value is the literal, and meta is a map.
      assert {:def, "x", 7, meta} = form
      assert is_map(meta)
    end

    test "a tool-call program's form exposes the {:tool_call, ...} node" do
      tools = %{"echo" => %PtcRunner.Tool{name: "echo", function: fn _ -> {:ok, "hi"} end}}
      assert {:ok, %Step{form: form}} = Lisp.run(~S|(tool/echo {})|, tools: tools)
      assert {:tool_call, "echo", _args} = form
    end

    test "form is nil-safe: a program still returns a usable form for a do-block" do
      assert {:ok, %Step{form: form}} = Lisp.run("(do (def a 1) (def b 2) (+ a b))")
      refute is_nil(form)
      # A do-block analyzes to a structured node a lens can descend.
      assert is_tuple(form)
    end
  end

  describe "AST-drift contract: form == independent parse+analyze of the same source" do
    # If ptc_runner reshapes its AST, these fail at the seam instead of silently
    # corrupting any consumer that walks Step.form.
    @sources [
      "(+ 1 2)",
      "(def x 41)",
      "(do (def a 1) (def b 2) (+ a b))",
      ~S|(let [x 1 y 2] (+ x y))|,
      ~S|(map (fn [n] (* n n)) [1 2 3])|,
      ~S|(if true 1 2)|,
      ~S|(filter (fn [n] (> n 1)) [1 2 3])|
    ]

    for src <- @sources do
      test "form matches parse+analyze for: #{src}" do
        src = unquote(src)
        assert {:ok, %Step{form: form}} = Lisp.run(src)

        {:ok, raw} = Parser.parse(src)
        {:ok, expected} = Analyze.analyze(raw)

        assert form == expected,
               "Step.form drifted from an independent parse+analyze of #{inspect(src)}. " <>
                 "If the AST shape changed intentionally, update consumers that walk Step.form."
      end
    end

    test "form round-trips through CoreToSource back to runnable source" do
      src = "(do (def x 5) (+ x 1))"
      assert {:ok, %Step{form: form, return: 6}} = Lisp.run(src)

      # The structured form renders back to source that runs to the same value,
      # proving form is a faithful, complete representation (not a lossy preview).
      rendered = CoreToSource.format(form)
      assert {:ok, %Step{return: 6}} = Lisp.run(rendered)
    end
  end
end
