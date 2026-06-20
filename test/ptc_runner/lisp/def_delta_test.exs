defmodule PtcRunner.Lisp.DefDeltaTest do
  @moduledoc """
  SPELL MOVE-A: `Step.def_delta` — the per-run def-delta emitted AT THE SOURCE.

  The runtime evaluates every `(def ...)` itself, so it can report exactly which
  names a run introduced or rebound. Emitting that on the Step means consumers
  (SpellAgent.Hist, TraceLog memory_diff) no longer snapshot-diff two full
  `memory` maps to recover what changed — the single source of truth is here.

  Contract:
    * `introduced` — a name absent from the entering memory (incl. a name bound
      to `nil`, distinguished by key presence, not value).
    * `changed` — a name present before with a different value.
    * no `removed` set — PTC has no `undef`, a delta can only add or rebind.
    * values are externalized identically to `Step.memory` (wire-equal).
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Step

  describe "introduced" do
    test "a fresh def from empty memory is introduced, not changed" do
      assert {:ok, %Step{def_delta: %{introduced: intro, changed: chg}}} =
               Lisp.run("(def x 7)")

      assert intro == %{"x" => 7}
      assert chg == %{}
    end

    test "multiple defs in one run are all introduced" do
      assert {:ok, %Step{def_delta: %{introduced: intro}}} =
               Lisp.run("(do (def a 1) (def b 2) (+ a b))")

      assert intro == %{"a" => 1, "b" => 2}
    end

    test "a def bound to nil is introduced (presence, not truthiness)" do
      assert {:ok, %Step{def_delta: %{introduced: intro}}} = Lisp.run("(def n nil)")
      assert Map.has_key?(intro, "n")
      assert intro["n"] == nil
    end

    test "a run with no def has empty introduced and changed" do
      assert {:ok, %Step{def_delta: %{introduced: %{}, changed: %{}}}} =
               Lisp.run("(+ 1 2)")
    end
  end

  describe "changed vs introduced against entering memory" do
    test "rebinding a name already in memory is changed, not introduced" do
      assert {:ok, %Step{def_delta: %{introduced: intro, changed: chg}}} =
               Lisp.run("(def x 99)", memory: %{"x" => 1})

      assert intro == %{}
      assert chg == %{"x" => 99}
    end

    test "a name in memory left untouched appears in neither set" do
      assert {:ok, %Step{def_delta: %{introduced: intro, changed: chg}}} =
               Lisp.run("(def y 2)", memory: %{"x" => 1})

      assert intro == %{"y" => 2}
      assert chg == %{}
      refute Map.has_key?(chg, "x")
      refute Map.has_key?(intro, "x")
    end

    test "rebinding to the SAME value is a no-op (neither introduced nor changed)" do
      assert {:ok, %Step{def_delta: %{introduced: %{}, changed: %{}}}} =
               Lisp.run("(def x 1)", memory: %{"x" => 1})
    end
  end

  describe "single-source-of-truth: delta reconciles with full memory" do
    test "applying the delta to entering memory reproduces Step.memory" do
      # Use user-defined names (not builtin names like `keep`, which externalize
      # to atoms) so entering keys and Step.memory keys are the same type. This
      # isolates the delta contract from the orthogonal memory-key
      # externalization quirk (binary builtin names -> interned atoms).
      initial = %{"held" => 0, "x" => 1}

      assert {:ok, %Step{memory: mem, def_delta: %{introduced: intro, changed: chg}}} =
               Lisp.run("(do (def x 5) (def fresh 9) held)", memory: initial)

      # The delta is exactly what a snapshot diff WOULD have recovered — but the
      # runtime computed it directly. Folding it onto the initial memory must
      # reproduce the final memory, proving no information is lost or invented.
      reconstructed = initial |> Map.merge(intro) |> Map.merge(chg)
      assert reconstructed == mem
      assert intro == %{"fresh" => 9}
      assert chg == %{"x" => 5}
    end
  end

  describe "property: introduced ∪ changed keys ⊆ final memory, disjoint from untouched" do
    use ExUnitProperties

    property "delta keys are a subset of final memory and fold back to it" do
      # Prefix all generated names with `v_` so they are user-defined names (never
      # builtin names), keeping memory-key externalization a pure identity on
      # binaries and isolating the delta contract from that orthogonal quirk.
      name = map(string(:alphanumeric, min_length: 1, max_length: 6), &("v_" <> &1))

      check all(
              entering0 <- map_of(name, integer()),
              fresh0 <- map_of(name, integer()),
              max_runs: 50
            ) do
        # fresh names must be disjoint from entering names (they are the
        # "introduced" set); drop any overlap from fresh.
        fresh = Map.drop(fresh0, Map.keys(entering0))
        entering = entering0

        defs = Enum.map_join(fresh, " ", fn {k, v} -> "(def #{k} #{v})" end)
        prog = "(do #{defs} 0)"

        assert {:ok, %Step{memory: mem, def_delta: %{introduced: intro, changed: chg}}} =
                 Lisp.run(prog, memory: entering)

        # introduced and changed are disjoint
        assert MapSet.disjoint?(MapSet.new(Map.keys(intro)), MapSet.new(Map.keys(chg)))
        # every delta key is present in the final memory
        for k <- Map.keys(intro) ++ Map.keys(chg), do: assert(Map.has_key?(mem, k))
        # all fresh names are introduced (none were in entering)
        assert MapSet.subset?(MapSet.new(Map.keys(fresh)), MapSet.new(Map.keys(intro)))
        # folding the delta onto entering reproduces the final memory
        assert Map.merge(Map.merge(entering, intro), chg) == mem
      end
    end
  end
end
