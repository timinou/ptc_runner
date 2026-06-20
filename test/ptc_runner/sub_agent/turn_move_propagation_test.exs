defmodule PtcRunner.SubAgent.TurnMovePropagationTest do
  @moduledoc """
  SPELL MOVE-A'/C': the per-run `%Step{}` Moves (`def_delta`, `form`) are
  projected onto every per-turn `%PtcRunner.Turn{}` the agent loop accumulates.

  Why this matters: spell `Hist.Recorder` iterates `step.turns` PER-TURN, so a
  per-run-only Step field never reaches it. These tests pin the contract the
  Hist cutover (PLAN-008 SEAM 1/3) depends on:

    * each turn carries its OWN def_delta + form (not the step's last run only),
    * folding the per-turn def_deltas in order reproduces the final memory
      (the equivalence that lets Hist delete its snapshot-diffing `map_delta`),
    * a turn with no eval (none scripted here) would carry nil — asserted at the
      unit level in `PtcRunner.TurnTest`.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  # A scripted LLM that replays a fixed list of responses, one per turn, by
  # counting the assistant turns already in the message list. Deterministic and
  # synchronous — no registry, no network.
  defp scripted(responses) do
    fn %{messages: messages} ->
      idx = Enum.count(messages, &(&1.role == :assistant))
      {:ok, Enum.at(responses, idx, List.last(responses))}
    end
  end

  defp fence(code), do: "```clojure\n" <> code <> "\n```"

  describe "Step -> Turn propagation across a multi-turn run" do
    test "each turn carries its own def_delta and form" do
      agent = SubAgent.new(prompt: "Test", max_turns: 3)

      responses = [
        fence("(def a 1)"),
        fence("(def b 2)"),
        fence("(return (+ a b))")
      ]

      {:ok, step} = Loop.run(agent, llm: scripted(responses), context: %{})

      turns = step.turns
      assert is_list(turns) and length(turns) == 3

      # Turn 1 introduced a; turn 2 introduced b; turn 3 introduced nothing.
      [t1, t2, t3] = turns

      assert t1.def_delta.introduced == %{"a" => 1}
      assert t2.def_delta.introduced == %{"b" => 2}
      assert t3.def_delta.introduced == %{}

      # Each turn's form is the executed CoreAST for THAT turn (a {:def, ...} or
      # {:call, {:var, "return"}, ...} tuple), never nil for an eval'd turn.
      assert t1.form != nil
      assert t2.form != nil
      assert t3.form != nil
      refute is_binary(t1.form), "form must be CoreAST data, not the source string"
    end

    test "fold of per-turn def_delta equals final memory (the Hist equivalence)" do
      agent = SubAgent.new(prompt: "Test", max_turns: 4)

      responses = [
        fence("(def x 1)"),
        fence("(def y 2)"),
        fence("(def x 99)"),
        fence("(return x)")
      ]

      {:ok, step} = Loop.run(agent, llm: scripted(responses), context: %{})

      folded =
        Enum.reduce(step.turns, %{}, fn turn, acc ->
          case turn.def_delta do
            %{introduced: intro, changed: chg} ->
              acc |> Map.merge(intro || %{}) |> Map.merge(chg || %{})

            _ ->
              acc
          end
        end)

      # The rebinding in turn 3 lands in `changed`, folds over the turn-1 value.
      assert folded["x"] == 99
      assert folded["y"] == 2

      # Folded delta == the memory the runtime itself reports. This is the
      # contract Hist relies on to stop snapshot-diffing.
      assert folded == step.memory
    end

    test "a rebind is reported as changed, not introduced, on the right turn" do
      agent = SubAgent.new(prompt: "Test", max_turns: 3)

      responses = [
        fence("(def x 1)"),
        fence("(def x 2)"),
        fence("(return x)")
      ]

      {:ok, step} = Loop.run(agent, llm: scripted(responses), context: %{})
      [t1, t2, _t3] = step.turns

      assert t1.def_delta.introduced == %{"x" => 1}
      assert t1.def_delta.changed == %{}
      assert t2.def_delta.introduced == %{}
      assert t2.def_delta.changed == %{"x" => 2}
    end
  end
end
