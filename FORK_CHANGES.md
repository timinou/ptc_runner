# Fork Changes — `timinou/ptc_runner` (branch `spell`)

This file tracks the **commit series** that diverges this fork from upstream
`andreasronge/ptc_runner`. It is the chronological ledger; `SPELL_PATCHES.md`
is the semantic, per-capability divergence reference (what each patch does and
why). Read both: this file answers "what commits did we add and in what order",
`SPELL_PATCHES.md` answers "what is the behavior and how to re-apply on rebase".

## Base

- **Upstream:** `andreasronge/ptc_runner` (the source repo this is forked from).
- **Fork base commit:** upstream `main` at the **0.12.0** release prep
  (`74af3a23` on this fork, identical to upstream `main` at fork time — the
  fork carried zero divergence before the `spell` branch).
- **Branch:** `spell`. Spell consumers (`beam/spell_agent`, `beam/ptc_runtime`)
  pin this fork as a git submodule at `beam/ptc_runner` and depend on it by
  path (`{:ptc_runner, path: "../ptc_runner"}`).
- **Version marker:** `mix.exs` carries `0.12.0-spell`.

## History of this fork

Earlier the spell patches lived against upstream **0.11.0** as a *stripped,
git-less vendored copy* (`beam/ptc_runner-vendored/`, plain files committed into
the spell monorepo). This branch is the migration to a real submodule **rebased
onto 0.12.0**: every spell patch was re-applied onto the maintainer's 0.12.0
tree (3-way merge against the 0.11.0 base), verified, and committed as the neat
per-patch series below. The 0.12.0 rebase pulled in the maintainer's work:
`TraceLog`, `PtcRunner.Session`, the upstream OpenAPI/MCP-HTTP transports, the
`tool/call`/`tool/servers` rename, and broad Clojure-conformance fixes.

## Commit series (oldest first)

Ported spell patches (the divergence that already existed against 0.11.0, now
re-applied onto 0.12.0). Commit order is dependency-correct: PATCH-3 (handles)
precedes PATCH-1 because PATCH-1's program-facing `handle?` predicate references
the `Handle` struct PATCH-3 introduces.

| commit | title | SPELL_PATCHES ref |
|---|---|---|
| `5e383451` | `chore(spell): mark fork base 0.12.0-spell` | PATCH-0 (scaffold) |
| `04776da0` | `feat(lisp): handle-aware builtins — park large tool results` | PATCH-3 |
| `5fa6f43b` | `feat(lisp): psettled — settled parallel map` | PATCH-1 |
| `bec72818` | `feat(lisp): preflight unbound-var hints` | PATCH-2 |
| `e81abd39` | `feat(lisp): strict accessors get! / get-in!` | PATCH-6 |
| `b88e206c` | `feat(lisp): try/catch/finally exception handling` | PATCH-8 |
| `6c3abdaf` | `feat(lisp): harness/ and keymap/ namespaces` | PATCH-N |
| `c7d7df7b` | `fix(lisp): actionable tool-error and unknown-tool messages` | BUG-462/463 |
| `9ca510b8` | `test(lisp): adapt upstream assertions to spell-patched messages` | (test reconciliation) |
| `c2aea3ee` | `fix(lisp): handle-safe tool-call ledger compaction` | PATCH-3 (0.12 integration fix) |

New capabilities added on this fork (the "Moves" — runtime support that lets
`SpellAgent.Hist` stop reconstructing structure the runtime already computes;
all WRITE-path / Elixir-core, the PTC sandbox cannot reach them):

| commit | title | SPELL_PATCHES ref |
|---|---|---|
| `35dce1f0` | `feat(lisp): Step.def_delta — per-run def-delta at the source` | MOVE-A |
| `67e8af11` | `feat(step): Step.freeze/1 — materialize parked handles at the owner` | MOVE-B |
| `effe383b` | `feat(step): Step.form — executed CoreAST as data` | MOVE-C |
| `b3fd78d4` | `feat(handle): expose deep_realize/1; Step.freeze delegates` | FEAT-002 |
| `7e885c8a` | `feat(turn): propagate Step.def_delta + Step.form to Turn (MOVE-A'/C')` | MOVE-A'/C' |

> The probe special form (labelled ordered investigation) and the `psettled`
> predicates ride inside the PATCH-1 commit (they share its eval/analyze
> machinery and were co-located in the original vendored tree).

## The Moves — why they exist

The spell consumer `SpellAgent.Hist` (a conversation-history substrate) was
re-deriving, from OUTSIDE the runtime, structure the runtime already computes
and then discards. Each Move emits that structure at the source so Hist becomes
a near-pure projection:

- **MOVE-A `Step.def_delta`** — the runtime evaluates every `(def …)`, yet
  `Step.memory` is a full SNAPSHOT, so Hist (`map_delta`) and `TraceLog`
  (`memory_diff`) each snapshot-diff two full maps to recover what changed.
  `Step.def_delta = %{introduced, changed}` is computed once at the source
  (entering vs final def memory). PTC has no `undef`, so there is no `removed`
  set and the omission-as-deletion ambiguity a downstream diff inherits cannot
  occur. Folding the delta onto entering memory reproduces `Step.memory` exactly.
- **MOVE-B `Step.freeze/1`** — a large tool result parks off-heap in
  `HandleStore`; a Step field holds a small `%Handle{}`. The store reaps cold
  entries, so a consumer that persists a handle and realizes it later RACES the
  reaper. `Step.freeze/1` materializes every handle at the OWNER (which knows
  the term is live now) into self-contained, serializable data; an unrealizable
  handle degrades to a `{:__frozen_unrealized__, reason, meta}` tombstone, never
  a crash. Hist can drop its own `Realize.walk` hot path.
- **MOVE-C `Step.form`** — `program` is a STRING; the runtime parsed it to a
  CoreAST to run it, then returned only the string, so structural lenses had to
  re-parse. `Step.form` carries the executed CoreAST as data (canonical
  `{:def, name, val, meta}` / `{:tool_call, name, args}` shape). Shipped with an
  AST-DRIFT CONTRACT test: `Step.form` must equal an independent
  `Parser.parse |> Analyze.analyze` of the same source, so a future AST reshape
  fails loudly at the seam instead of silently corrupting recorded lenses. This
  subsumes the once-planned `form_tree` projection (the AST *is* the tree).

## Upstream rebase procedure

1. Add upstream as a remote and fetch:
   `git remote add upstream https://github.com/andreasronge/ptc_runner.git && git fetch upstream`.
2. Rebase or merge `spell` onto the new upstream tag. The patches above are
   structured so each is a single, file-scoped commit; re-apply per
   `SPELL_PATCHES.md` (each entry lists its touched files).
3. Re-verify all three consumers:
   - fork: `cd beam/ptc_runner && mix test test/ptc_runner/lisp/`
   - `cd beam/ptc_runtime && mix test`
   - `cd beam/spell_agent && mix test`
4. Bump the `-spell` version suffix in `mix.exs` and update this file.

## Verification at time of writing

- fork lisp suite: **3400 passed** (incl. the MOVE-A/MOVE-C generative +
  AST-drift contract tests), 0 failures.
- `beam/ptc_runtime`: **135 passed** (handle offload, psettled, try/catch,
  session bindings, probe), 0 failures.
- `beam/spell_agent`: **331 passed** (Hist, TUI, session suites), 0 failures.
