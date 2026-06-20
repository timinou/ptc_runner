# Spell-fork patches to ptc_runner (base 0.12.0)

This file documents the deliberate divergence of the spell fork
(`timinou/ptc_runner`, branch `spell`) from upstream `ptc_runner`
(github.com/andreasronge/ptc_runner). It is the SEMANTIC, per-capability
reference (what each patch does, why, and which files it touches). The
chronological commit-series ledger lives in `FORK_CHANGES.md` at the fork root.
Re-apply these on every upstream rebase.

> **History:** these patches originally targeted upstream **0.11.0** as a
> stripped, git-less vendored copy (`beam/ptc_runner-vendored/`). They have since
> been re-applied onto upstream **0.12.0** and the fork is now a proper git
> submodule at `beam/ptc_runner` (version marker `0.12.0-spell`). Most patch
> bodies are unchanged; the 0.12 rebase added one integration fix (PATCH-3
> handle-safe ledger compaction) and three new capabilities (MOVE-A/B/C, see the
> end of this file). The file/line references below were written against 0.11.0
> and may have drifted by a few lines under 0.12; the function/clause names are
> stable. Mirrors the `crates/brush-core-vendored/SPELL_PATCHES.md` precedent.

Design context: `specs/beam-orchestrator/06-execute-substrate.md` (D-1 fork
decision and the patch roadmap D-2/D-4/D-5).

## PATCH-0 (F0): vendoring scaffold

**Disposition**: spell-specific (not upstreamable).

- `mix.exs` rewritten: dev-only deps dropped (`ptc_viewer` path dep, credo,
  dialyxir, ex_doc, benchee, ex_dna, recon, usage_rules, stream_data), hex
  packaging/docs config dropped, version `0.11.0-spell`. Optional integrations
  (`req`, `req_llm`, `kino`) remain optional and unfetched.
- `lib/mix/` (upstream's mix tasks: ptc.repl, ptc.smoke, ptc.dna, ...) deleted —
  they assume upstream's dev tree and are dead weight as a path dep.
- Upstream `test/` was never shipped in the hex package; the fork's behavior
  is covered by `beam/ptc_runtime/test/` (peer/bridge/robustness suites)
  plus fork-targeted tests added alongside each patch below.

## PATCH-1 (W1, D-4): `psettled` — settled parallel map ✅ LANDED

**Disposition**: upstreamable (PR candidate).

`psettled` is `pmap` with a SETTLED collector: a per-element *logical* failure
(tool error, raised exception, `(fail …)`, `(return …)`) becomes a settled
value instead of aborting the whole run. Successes are `{"ok" => v}`, failures
`{"err" => reason-string}`. `pmap` semantics are unchanged.

Resource-exhaustion kills (per-worker heap cap, shared deadline,
`:parallel_capacity_exceeded`) STILL abort both modes — a program must not be
able to settle past a global safety limit. On a heap/timeout kill the worker
process is dead and cannot settle anyway; the one nested-`ExecutionError`
rescue explicitly re-raises stable resource reasons.

Prelude predicates ship with it — errors as data, no exception primitive:
`ok?`, `err?` (classify settled maps), `unwrap-or` (settled `{"ok"=>v}` → v,
else default).

### Files touched

```
lib/ptc_runner/lisp/eval.ex          — :psettled do_eval clause; shared
                                       eval_parallel_map/4 (pmap+psettled);
                                       parallel_worker_fun/3 + settle_ok/_err
                                       + settled_reason_string +
                                       stable_resource_error?; mode threaded
                                       into collect_runner_results +
                                       parallel_error_type(:psettled)
lib/ptc_runner/lisp/analyze.ex       — dispatch + analyze_psettled/2;
                                       :psettled in the special-form list
lib/ptc_runner/lisp/source_atoms.ex  — psettled in the bounded atom vocab
lib/ptc_runner/lisp.ex               — collect_tool_names +
                                       collect_undefined_vars :psettled clauses
lib/ptc_runner/lisp/core_to_source.ex— format + collect_var_refs :psettled
lib/ptc_runner/lisp/runtime/predicates.ex — ok?/err?/unwrap_or
lib/ptc_runner/lisp/runtime.ex       — defdelegate ok?/err?/unwrap_or
lib/ptc_runner/lisp/env.ex           — register :ok? :err? :"unwrap-or"
priv/functions.exs                   — psettled, ok?, err?, unwrap-or docs
```

Tests: `beam/ptc_runtime/test/psettled_test.exs` (12, direct `Lisp.run`).
Gotcha: group the `:psettled` do_eval clause WITH `:pmap`; keep helpers in the
parallel-helper region — a helper between do_eval clauses trips Elixir's
clause-grouping warning.

Review fixes (W1 reviewer swarm):
- `pmap_call` is tagged `type: :psettled`, so `SubAgent.Loop.emit_pmap_telemetry`'s
  `case` needed a `:psettled -> [:pmap]` clause (it's a pmap variant; emits
  under the established `[:pmap, ...]` event family). Without it a psettled
  program crashed `CaseClauseError` on the SubAgent path (the PR consumer).
- `ok?`/`err?`/`unwrap-or` route key access through `FlexAccess.flex_fetch/2`
  (like `get`/`contains?`), NOT a bare `%{"ok" => _}` pattern: a hand-built
  `{:ok v}` literal is `%LispKeyword{name: "ok"}`-keyed mid-eval (only
  normalized to a binary at final output), so the bare pattern silently
  returned false. psettled's own output is binary-keyed and worked either way;
  the FlexAccess path makes both forms classify identically.
- Added the highest-stakes test: a per-worker heap-cap kill must ABORT a
  psettled run (`:memory_exceeded`), never settle as `{"err"}`.

## PATCH-2 (W1, D-5): preflight lint hints ✅ LANDED

**Disposition**: upstreamable (PR candidate).

Key finding: the unbound-var gate ALREADY runs pre-effect. `execute_program`'s
`compile_fn` does parse → symbol-limit → analyze → `check_undefined_vars` →
`check_undefined_tools` BEFORE any tool executes, so a hallucinated builtin
(`map-vals`) fails with 0 tool calls already. No separate Peer pre-pass is
needed (it would double-parse); the value-add is HINTS.

The rich hint logic (`Helpers.format_closure_error/1`: special-form, known
Clojure-name alternative, hyphen-vs-underscore, jaro-nearest-builtin) existed
but only fired on the *runtime* closure path. This patch routes the
pre-execution gate AND `validate/2` through it:

- `check_undefined_vars` builds per-var hinted messages (single var → one
  rich line; multiple → a bulleted block).
- `validate/2` returns hinted strings instead of bare names.
- Names are resolved to atoms via `SourceAtoms.intern/1` (the bounded-vocab
  interner) — NOT `String.to_atom/1`, which would reopen the atom-table
  growth vuln (#953). Unknown names stay binaries; the jaro path handles them.
- Added high-frequency hallucinations to `@clojure_alternatives` that jaro
  distance misses: `map-vals`→update-vals, `map-keys`→update-keys,
  `dedupe-by`, `group-by-vals`.

### Files touched

```
lib/ptc_runner/lisp.ex               — undefined_vars_message/1 +
                                       undefined_var_hint/1; check_undefined_vars
                                       and validate/2 route through them
lib/ptc_runner/lisp/eval/helpers.ex  — @clojure_alternatives gains the
                                       map-vals/map-keys/dedupe-by/group-by-vals
                                       entries
```

Tests: `beam/ptc_runtime/test/preflight_lint_test.exs` (7 — pre-effect proof
via a tool-call tracker + hint coverage).

## PATCH-3 (W2, D-2): handle-aware builtins ✅ LANDED (navigation/slice subset)

**Disposition**: spell-specific.

A tool result is copied onto the sandbox worker's heap the instant the Peer
replies it (`GenServer.reply`, peer.ex) — that's the E1 / BUG-426 OOM point. A
large result now PARKS in a `HandleStore` process BEFORE the reply; the worker
gets a small `%Handle{}`. Handle-aware builtins run their projection IN the
store process (where the term lives) and copy back ONLY the slice. Heap then
charges the program for what it computes on, never for what a tool returned.

Key correctness point: NOT an ETS handle. `:ets.lookup` copies the whole term
to the caller, re-landing it on the sandbox heap — defeated. Projection must
run where the term lives, so the store is a process and projections are a
`GenServer.call` whose REPLY is the (small) slice.

Sizing uses `:erlang.external_size/1` (serialized bytes), NOT
`:erts_debug.flat_size` — the latter excludes off-heap binary payloads, and an
org dashboard is mostly string bodies, so flat_size would never trip the park
threshold (the exact payload this targets). Threshold 256KB.

Projectable (navigation/slice) builtins this wave: `count get get-in keys vals
select-keys contains? first nth take`. A NON-projectable builtin over a handle
realizes it first (correctness fallback). Transform-over-handle
(`map`/`filter`/`group-by`/`reduce`) is DEFERRED — a program projects to a
slice first. Oversized projection results re-park as nested handles.

GC is exec-scoped: one `release(exec_id)` at execute teardown drops every term
that execute parked. A handle cannot escape its execute — `ensure_encodable`
runs inside the execute proc and a `%Handle{}` is not JSON-encodable, so a raw
handle return fails as an unencodable return rather than leaking a stale ref.

### Files touched

```
NEW lib/ptc_runner/lisp/handle.ex        — %Handle{} struct + describe/meta
NEW lib/ptc_runner/lisp/handle_store.ex  — owner GenServer: put/project/realize/
                                           release, in-store projections, repark
NEW lib/ptc_runner/lisp/handle_ops.ex    — builtin name + args → projection tuple
lib/ptc_runner/lisp/eval/apply.ex        — handle-aware %Builtin{} dispatch +
                                           apply_handle_projection/realize_handle
lib/ptc_runner/lisp/eval/context.ex      — handle_store + exec_id fields
lib/ptc_runner/lisp.ex                   — thread handle_store/exec_id run→eval
(ptc_runtime) lib/ptc_runtime/application.ex — start HandleStore under supervisor
(ptc_runtime) lib/ptc_runtime/peer.ex    — park large results pre-reply
                                           (maybe_park), exec_id in pending,
                                           release bucket on execute_done,
                                           handle_store+exec_id into run_opts
```

W2b cost observability: `handle?` / `handle-meta` builtins read the handle
struct directly (no store roundtrip, no realize — proven under a 1MB heap) so a
program can inspect a parked value's bytes/shape/keys before projecting.
`HandleStore.stats/2` + a Peer log line on execute_done report offloaded bytes.

Review fixes (W2 reviewer swarm):
- [P1] `apply_handle_projection` located the handle positionally (`[handle|_]`),
  which is wrong for seq ops: `(take n h)` puts the handle LAST, so `take`
  crashed `FunctionClauseError`. Now located by `Enum.find(&Handle.handle?/1)`.
- [P2] closure contexts (`eval_closure_args`, `do_execute_closure`) built fresh
  `EvalContext.new` WITHOUT `exec_id`/`handle_store`, so an oversized re-park
  from inside a `(map #(get h %) ks)` closure bucketed under `nil` — a bucket
  `release/1` never sweeps → unbounded cross-execute leak. Both now propagate
  them. (pmap workers were already safe: they struct-UPDATE the ctx.)
- [P2] `maybe_park` excluded bare binaries, so a multi-MB STRING tool result
  (file body / HTML) bypassed offload onto the sandbox heap. Now parks
  binaries too; added a string `take` projection in the store.

Tests: `handle_store_test.exs` (11 unit), `handle_offload_test.exs` (12 e2e):
the DECISIVE control (same program OOMs `:memory_exceeded` without offload at a
1MB heap, succeeds with it), the `take`-handle-last regression, large-string
parking, and the nil-bucket leak guard (asserts the unreleasable bucket stays
empty after an in-closure re-park).

## PATCH-4 (W3, D-6): session bindings ✅ LANDED

**Disposition**: mostly spell-specific (the rehome store op is reusable). The
binding mechanism itself reuses upstream's `def`→memory machinery unchanged.

Key decision: NO parallel `bind/<key>` namespace. ptc_runner already persists
`(def x v)` into `step.memory`, surviving across runs IF the caller threads
memory back. The Peer simply does that threading — `st.memory` seeds each
execute's `:memory` opt; a successful run's `step.memory` is captured back into
session state. One need, one implementation.

Commit rules (all in ptc_runtime peer.ex, not the fork):
- Bindings commit on a SUCCESSFUL run regardless of whether the RETURN encodes
  — bare `(def x v)` returns a non-encodable Var yet must bind.
- A program that ended via `(fail ...)` (return `{:__ptc_fail__, _}` inside the
  `:ok` tuple) does NOT commit — a failed program leaves bindings untouched,
  same as the `{:error, step}` path.
- Capture runs in the serialized GenServer, so concurrent executes can't
  interleave the merge (last-completed wins — fine for a sequential REPL cache).

Handle interaction (the subtle part): a `(def x (tool/big {}))` binds a
%Handle{} whose per-execute store bucket is released at THIS execute's
teardown. Realizing it would (a) lose the D-2 offload benefit and (b) copy a
multi-MB term onto the NEXT execute's bounded compile heap, OOMing the compile
phase. Instead `persist_bindings` RE-HOMES bound handles into a persistent
`@session_bindings` bucket (never released by an execute; swept at BEAM exit)
via the new `HandleStore.rehome/3` — the binding stays a small handle, projects
lazily next execute, keeps the offload benefit. A rebind leaves the prior term
in the session bucket until teardown (bounded session-scoped cost).

### Files touched

```
lib/ptc_runner/lisp/handle_store.ex      — rehome/3 + {:rehome} handler +
                                           drop_from_bucket/3
(ptc_runtime) lib/ptc_runtime/peer.ex    — State.memory; seed :memory per
                                           execute; capture on execute_done
                                           (4-tuple {:execute_done,id,res,mem});
                                           persist_bindings + @session_bindings;
                                           run_program returns {wire, memory};
                                           fail-signal guard
```

Review fixes (W3 + holistic reviewer swarm):
- [P2] Binding capture now MERGES into session memory (`Map.merge(st.memory,
  …)`) instead of replacing it wholesale. Two concurrent executes binding
  DIFFERENT names both survive; a wholesale replace silently dropped the
  earlier non-conflicting binding (executes can overlap — admission ceiling 8).
- [P2] `persist_bindings` now also parks a LARGE non-handle computed binding
  (e.g. `(def x (range 0 200000))` — never a tool result, so offload never saw
  it). Seeded verbatim it would OOM the NEXT execute's smaller bounded compile
  heap (~10MB), poisoning every later execute. Parking it into the session
  bucket keeps the binding a small handle. Same `external_size >= 256KB` gate.

Tests: `session_bindings_test.exs` (9): cross-execute reuse, accumulation,
shadowing, bare-def-still-binds, fail-doesn't-commit, unbound-still-errors, the
merge guard (a binding survives a later different-name commit), the
large-computed-binding park (a def'd 200k-int list doesn't compile-OOM the next
execute), and the handle case (a def'd 400-item dashboard reusable next execute
via rehome — no compile OOM, no stale handle).


## PATCH-5: Session-store reaper (LRU + ceiling)

**Disposition**: spell-specific (eviction policy atop the upstreamable handle protocol).

**Rationale**: The  (PATCH-4) is NEVER released by an execute
teardown — values parked there survive indefinitely. Without a ceiling, a long
session (or W4 unattended re-execution) leaks unbounded heap (each tick parks
every binding again). The reaper adds LRU eviction when the session bucket's
total  exceeds a configurable ceiling.

### Design

- **Last-access timestamps**: a parallel  map () tracks
   per session-bucket term id, updated on
  every project/realize/rehome touch. Exec-bucket terms are NOT tracked — the
   sweep is their GC. A parallel map (not an extended tuple) keeps
  the pattern match on  unchanged everywhere.
- **Eviction**: on / INTO the session bucket, after inserting,
  while total  exceeds the ceiling, the COLDEST session-bucket
  term (min access_ts) is evicted, and the check recurses.
- **Tombstone set**: evicted ids are retained in a bounded MapSet (max 100
  entries, FIFO eviction on overflow) so // of a
  reaped handle returns  — distinguishable from
   (released exec bucket) or never-existed.
- **Ceiling**: default 64 MB. Configurable via  call. The Peer
  sends the operator's  setting (converted from MB
  to bytes at the Node boundary) in the  frame → .
- **Bytes live in the HandleStore** (the session bucket holds all parked
  values).  is only the binding INDEX (small Handle structs).
  When a Handle is evicted, the index entry remains; the next read fails loud
  with the evicted typed error.

### Evicted-read semantics

Reading an evicted session binding fails LOUD on BOTH access paths — there is
no silent degradation (that would be the plausible-but-wrong class the E7
hardening removes):
- projection path (count/get/take over the handle) → `{:error, {:evicted, id}}`
  from `HandleStore.project`, mapped in `apply.ex apply_handle_projection` to the
  runtime error `"binding evicted (session store ceiling); re-run to rebind"`.
- realize path (a NON-projectable builtin like `reverse`/`frequencies` over the
  handle) → `apply.ex realize_handle` RAISES the same `ExecutionError`. (Review
  fix: this clause originally degraded to nil; corrected to raise so both paths
  are loud. Regression test: "a non-projectable builtin over an evicted binding
  fails LOUD".)
- rehome-time (the reaper evicts a handle that `persist_bindings` is about to
  re-home) → `peer.ex persist_bindings` keeps the original handle as a stable
  tombstone (was an unhandled case → CaseClauseError crashing the Peer; review
  fix keeps the binding loud-on-next-read instead of crashing).

The bounded evicted/tombstone set gives a distinguishable `{:evicted, id}` at
the HandleStore boundary, separate from `:stale_handle` (a released exec bucket)
and from a never-existed binding (unbound var).


### Settings plumbing (mirrors FEAT-791 exec-max-heap-mb exactly)



### Files touched



### Tests

beam/ptc_runtime/test/session_store_eviction_test.exs (4):
1. Mass park (~1000 large values at 1MB ceiling) stays bounded
2. Park past ceiling evicts the coldest binding
3. Reading an evicted binding yields a typed error (not stale value, not crash)
4. A hot (repeatedly read) binding survives while cold ones are evicted
## PATCH-6: Strict accessors `get!`/`get-in!` (E7 nil-poison opt-in)

**Disposition**: upstreamable.

**Rationale**: verified that default access (`get`/`get-in`) already resolves
keyword→string keys correctly — `(:items {"items" 5})` => 5. The REAL runtime
poison is a genuinely MISSING key returning `nil`, which collection ops silently
absorb: `(count (:absent m))` → 0, `(map f (:absent m))` → []. Arithmetic
already fails loud (`(+ 1 nil)` → type_error). nil-punning is RELIED UPON across
`priv/functions.exs`, so default access MUST stay nil-returning.

The fix is a NEW opt-in strict accessor, NOT a change to `get`/`get-in`:
- `get!/2` — like `get/2` but fails loud on missing key (uses `flex_fetch` to
distinguish `{:ok, nil}` from `:error`, so a present nil-valued key returns nil).
- `get-in!/2` — like `get-in/2` but fails loud on first absent path segment.

Both register as `{:normal, ...}` (fixed-arity) builtins in env.ex, not
`multi_arity` (no default argument — the point is to fail, not default).

### Files touched

```
lib/ptc_runner/lisp/runtime/map_ops.ex  — get!/2, get_in!/2 + step helpers
lib/ptc_runner/lisp/runtime.ex           — defdelegate get!/2, get_in!/2
lib/ptc_runner/lisp/env.ex               — args_specs + builtin registrations
priv/functions.exs                       — catalog entries (ptc_extension?: true)
(ptc_runtime) test/nil_poison_test.exs   — 8+ tests covering present/absent/
                                           nil-value/back-compat/psettled compose
```

## PATCH-7 (W4, FEAT-810): parse-only `validate` peer method ✅ LANDED

**Disposition**: spell-specific (the Peer protocol method; the underlying
`PtcRunner.Lisp.validate/2` is upstream and unchanged).

Stored programs (W4) need a STORE-time check that a program parses and uses no
unknown builtins/vars, running ZERO tool calls and ZERO effects — so a typo can
never be persisted as a live tile and then fail effectfully on a later re-run.

`PtcRunner.Lisp.validate/2` already does exactly this (parse + Analyze +
`collect_undefined_vars`, with the PATCH-2 "Did you mean" hints, all inside
`Sandbox.run_bounded`). PATCH-7 only EXPOSES it over the Peer protocol:

- `beam/ptc_runtime/lib/ptc_runtime/peer.ex` — new `handle_request("validate",
  id, params, st)` clause: runs `PtcRunner.Lisp.validate(program)` and replies
  `%{"ok" => true}` or `%{"ok" => false, "errors" => [hint, ...]}`. Available
  pre-init (touches no catalog state). Inserted before the method-not-found
  fallback, in the helper region (no clause-grouping warning).

Node side (not in the fork): `client.ts` gains `validate(program)`; `execute.ts`
gains `validateProgram` + `runStored`; the read-only guard + store-time
validation live in `stored-program.ts`. The fork change is solely the Peer
method.

Tests: `packages/coding-agent/src/tools/ptc-runtime/stored-program.test.ts`
(20: read-only guard units + real-BEAM round-trip/validate/signature).

## PATCH-8 (FEAT, execute-ergonomics): `try`/`catch`/`finally` ✅ LANDED

**Disposition**: upstreamable (PR candidate) — a faithful Clojure subset feature.

Clojure-shaped exception handling: `(try body… (catch e handler…) (finally
cleanup…))`. Both `catch` and `finally` are optional trailing clauses (catch
before finally). The catch binds ONE symbol to the error value. This is the
SEQUENTIAL analogue of PATCH-1's `psettled` (per-element settling) — for a single
fallible step or a guaranteed `finally` cleanup.

Semantics (faithful to Clojure over BEAM `try/rescue/catch/after`):

- `catch` traps BOTH PTC error channels: the `{:error, reason}` RETURN TUPLE
  that `apply.ex` produces for most logical errors (unbound var, arithmetic,
  type, arity), a raised `ToolExecutionError` (tool failure), and the
  `{:fail_signal, v}` throw from `(fail v)` (binds the raw `v`, not a string).
- `(return v)` is NOT trapped — it bubbles to the enclosing return boundary
  (Clojure non-local return); `finally` still runs as it passes through.
- `finally` runs on EVERY exit path (normal / caught / re-raised / return /
  fail); its value is discarded.
- the catch var binds ONLY inside the handler (handler-local scope, like a
  `let`); `closure_capture` treats it as bound so a `try` inside an `fn` is
  free-var-correct.

**SAFETY (the load-bearing invariant)**: `try` must NEVER let a program swallow a
global safety limit. A heap/timeout/capacity kill terminates the BEAM process
before any rescue runs (uncatchable by construction); the one catchable form — a
nested `ExecutionError` carrying a stable resource reason
(`:memory_exceeded` / `:timeout` / `:parallel_capacity_exceeded`) — is RE-RAISED
past the handler (mirrors the `psettled` worker rescue + `stable_resource_error?`).
`finally` still runs on that re-raise, then the kill propagates. A dedicated
SAFETY test wraps a heap-cap kill in `(try … (catch e "SWALLOWED"))` and asserts
the run aborts with `:memory_exceeded`, never the handler value.

W4-write interaction: `try` is control-flow, not a transaction boundary. A
caught error means the PROGRAM succeeds → file writes COMMIT (the transaction
journal keys rollback on program-level failure, `execute.ts`). An UNCAUGHT
failure still rolls back. Documented in `prompts/tools/execute.md`.

### Files touched

```
lib/ptc_runner/lisp/analyze.ex        — dispatch_list_form :try; analyze_try +
                                       split_trailing_clause + catch/finally
                                       sub-analyzers → {:try, body, catch, finally}
lib/ptc_runner/lisp/eval.ex           — do_eval({:try,…}) over try/rescue/catch/
                                       after (both error channels + stable-
                                       resource re-raise); run_try_catch /
                                       run_try_finally / stable_execution_error? /
                                       error_reason_to_value helpers
lib/ptc_runner/lisp/closure_capture.ex — {:try,…} free-var clause (catch var
                                       handler-local)
lib/ptc_runner/lisp/core_to_source.ex — format({:try,…}) round-trip + do-splice
lib/ptc_runner/lisp/eval/helpers.ex   — :try in @special_forms (closure-error hint)
lib/ptc_runner/lisp/source_atoms.ex   — try/catch/finally in @special_forms
```

Tests: `beam/ptc_runtime/test/try_catch_test.exs` (21 over real BEAM via
`PtcRunner.Lisp.run/2`: normal/catch/finally/return-bubbling/nesting/closure-
capture/let-usage + the SAFETY heap-cap-abort invariant + an analysis-error
case). Full `ptc_runtime` suite stays green (113 tests + 5 properties).

EMPIRICAL notes (cost real iterations): (1) the catch-var symbol is the INTERNED
name — an ATOM only if in the bounded vocab, else a BINARY — so the analyzer
guard accepts `is_atom or is_binary` and the handler binding key matches
`{:var, name}` resolution. (2) PTC has TWO error channels (tuple + raise); a
first cut that only rescued raises missed every `{:error, reason}` tuple error.
(3) tool failures RAISE `ToolExecutionError` (not a tuple) — needs its own rescue
arm. (4) top-level `(return v)`/`(fail v)` surface as `{:__ptc_return__, v}` /
`{:__ptc_fail__, v}` sentinels at the program boundary.

## Upstream rebase procedure

1. Fetch the new hex tarball into a scratch dir.
2. Diff `lib/` against this tree; re-apply PATCH-1..N (each patch lists its
   files when it lands).
3. Re-run `cd beam/ptc_runtime && mix deps.get && mix test`.
4. Update the version suffix in `mix.exs` and this header.

## PATCH-N (PLAN-346 W3): `harness/` + `keymap/` namespaces ✅ LANDED

**Disposition**: spell-specific (the spell_agent inspector's Reaction DSL).

Two sibling namespaces alongside `tool/`/`data/`/`budget/`, for the homoiconic
keybinding system (PLAN-346). Both route through the EXISTING tool-call machinery
as qualified tool names (`"harness/<name>"`, `"keymap/<name>"`), so they inherit
all of its limits/tracing/caching/undefined-var analysis with no new eval path.

- `lib/ptc_runner/lisp/source_atoms.ex`: add `harness keymap` to
  `@bounded_namespaces` (so `ns/key` interns as `{:ns_symbol, ns, key}`), and the
  verb names (`state cursor-id descendants ancestors expand collapse toggle focus
  cursor scroll turn`, `bind unbind show intents define-reaction`) to
  `@qualified_keys`.
- `lib/ptc_runner/lisp/analyze.ex`: in `dispatch_list_form/4` (call position) and
  `do_analyze/2` (value position), route `{:ns_symbol, ns, name}` for
  `ns in [:harness, :keymap]` to a `{:tool_call, "<ns>/<name>", …}` /
  `{:runtime_callable, ns, :"<ns>/<name>"}`.
- `lib/ptc_runner/lisp/runtime_callable.ex`: extend `@type namespace` and add a
  `core_call/2` clause for `:harness`/`:keymap` (name is already qualified).
- `lib/ptc_runner/lisp.ex`: `collect_tool_names/2` collects the qualified names
  for the two namespaces (value-position callables) like `tool/`.

The host (`SpellAgent.Harness.tools/2`) registers the qualified names in the
tools map; `SpellAgent.Tui.Reaction.Ptc` runs a stored reaction with the gaze
bound as `data/ui` and the forest as `data/forest`.

## PATCH-3 follow-up (0.12 rebase): handle-safe tool-call ledger compaction ✅ LANDED

**Disposition**: spell-specific (handle-system compatibility with 0.12).

ptc_runner 0.12 added ledger result-size compaction
(`Eval.Context.append_tool_call` → `compact_ledger_entry/2` → `retained_size/2`
→ `referenced_binary_size/1`) that runs WHILE recording a tool call. PATCH-3
parks large tool results as `%PtcRunner.Lisp.Handle{}`, which satisfies
`is_map/1` but is NOT `Enumerable`, so `referenced_binary_size` crashed
`protocol Enumerable not implemented for Handle` for ANY program that called a
tool returning a large (parked) result — even one that discarded the result.
0.11 never sized the recorded result, so this is purely a 0.12-rebase gap.

Fix (`lib/ptc_runner/lisp/eval/context.ex`): `compact_ledger_entry` gets a
`%Handle{}` clause that stores the handle's small carried `meta` summary
(`%{"__type__" => "ptc_runner.lisp.handle", "meta" => meta}`) instead of the raw
struct; `referenced_binary_size` gets a `%Handle{}` → 0 guard plus an
`is_struct` guard so a nested handle (or any other struct) can never re-trigger
the protocol crash. Non-handle results keep byte-identical compaction.

Tests: `beam/ptc_runtime/test/handle_offload_test.exs` (12, all green).

---

# Moves — new capabilities (added on the 0.12 fork)

The Moves are NOT ports; they are new runtime support added so the spell
consumer `SpellAgent.Hist` can stop reconstructing, from outside, structure the
runtime already computes and discards. All are WRITE-path / Elixir-core; the
PTC sandbox cannot reach them. Each is one file-scoped commit (see
`FORK_CHANGES.md`).

## MOVE-A: `Step.def_delta` — per-run def-delta at the source ✅ LANDED

**Disposition**: upstreamable (a generally useful "what changed this run" field).

The runtime evaluates every `(def …)` itself, yet `Step.memory` is a full
SNAPSHOT, so `SpellAgent.Hist.Recorder.map_delta` and
`TraceLog.TurnEvent.memory_diff` each snapshot-diff two full maps to recover
what a run changed — and inherit the deletion-by-omission ambiguity that diff
carries. Emit the delta at the source instead.

- `EvalContext` snapshots the entering def memory (`initial_user_ns`) at `new/6`
  and never mutates it.
- `Step.def_delta = compute_def_delta(initial_user_ns, user_ns)` =
  `%{introduced: %{name => value}, changed: %{name => value}}`. `introduced` is
  a name absent before (presence-checked, so `(def x nil)` is a real
  introduction); `changed` is a name rebound to a different value. No `removed`
  set — PTC has no `undef`, so omission-as-deletion cannot occur, which is
  exactly why a source-emitted delta is unambiguous where a snapshot diff is
  not. Values externalized identically to `Step.memory` (wire-equal); folding
  the delta onto entering memory reproduces `Step.memory` exactly.

### Files touched

```
lib/ptc_runner/lisp/eval/context.ex  — :initial_user_ns field + new/6 snapshot
lib/ptc_runner/step.ex               — :def_delta field + @type
lib/ptc_runner/lisp.ex               — compute_def_delta/2; emit in Step build
```

Tests: `test/ptc_runner/lisp/def_delta_test.exs` (9, incl. a generative
fold-back property).

## MOVE-B: `Step.freeze/1` — materialize parked handles at the owner ✅ LANDED

**Disposition**: spell-specific (depends on the PATCH-3 handle system), but a
clean "give me a Step safe to persist/serialize" API.

`HandleStore` reaps cold session entries under a ceiling, so a consumer that
persists a `%Handle{}` and realizes it later RACES the reaper. `SpellAgent.Hist`
worked around this with its own `Realize.walk` on the write path, materializing
from OUTSIDE while hoping the term is still live. Move the freeze to the owner.

`Step.freeze/1` deep-walks the handle-bearing Step fields (`return`, `memory`,
`def_delta`, `tool_calls`, `pmap_calls`, `turns`), realizing each `%Handle{}`
through its store (recursively — a realized value may nest handles) into
self-contained data. An unrealizable handle degrades to a
`{:__frozen_unrealized__, reason, meta}` tombstone (meta = the cheap
descriptor) instead of raising. A handle-free Step is unchanged. The runtime
owns the store and knows the term is live at freeze time, so the race is gone;
Hist can call `Step.freeze(step)` and drop its `Realize` hot path.

### Files touched

```
lib/ptc_runner/step.ex  — freeze/1, unrealized?/1, freeze_term/freeze_handle/freeze_struct
```

Tests: `test/ptc_runner/step_freeze_test.exs` (6, incl. nested-handle recursion
and the released-term tombstone path).

## MOVE-C: `Step.form` — executed CoreAST as data ✅ LANDED

**Disposition**: upstreamable (a generally useful "the program as data" field).

`program` is a STRING; the runtime parsed it to a CoreAST to run it, then
returned only the string, so structural lenses had to re-parse and only worked
when something already held the tuple form. Stop discarding the structure.

- `EvalContext` retains the executed CoreAST (`core_ast`, set once at the
  top-level `eval_with_context`, `nil` for nested closure contexts).
- `Step.form = ctx.core_ast` — the canonical `Analyze` shape
  (`{:def, name, val, meta}` / `{:tool_call, name, args}`), so a lens walks a
  real tree instead of re-parsing.

Ships the load-bearing **AST-DRIFT CONTRACT** test: `Step.form` MUST equal an
independent `Parser.parse |> Analyze.analyze` of the same source, and
round-trips through `CoreToSource.format` back to runnable source. If a future
ptc_runner reshapes its AST, this fails LOUDLY at the seam instead of silently
corrupting any consumer that walks `Step.form`. This subsumes the once-planned
`form_tree` projection (the AST *is* the tree).

### Files touched

```
lib/ptc_runner/lisp/eval/context.ex  — :core_ast field + new/6 from opts
lib/ptc_runner/lisp/eval.ex          — set :core_ast on eval_with_context
lib/ptc_runner/step.ex               — :form field + @type
lib/ptc_runner/lisp.ex               — emit form: ctx.core_ast in Step build
```

Tests: `test/ptc_runner/lisp/step_form_test.exs` (12, incl. the 7-source
AST-drift contract + a CoreToSource round-trip).

## MOVE-A'/C': propagate `Step.def_delta` + `Step.form` to `Turn` ✅ LANDED

**Disposition**: spell-specific plumbing (depends on MOVE-A/MOVE-C), small and
upstreamable.

MOVE-A/MOVE-C land their fields on a per-RUN `%PtcRunner.Step{}` (one
`Lisp.run`). But a multi-turn agent run accumulates per-run results into
`step.turns` as `%PtcRunner.Turn{}`, and a per-turn consumer (`SpellAgent.Hist`
records PER TURN) only ever sees the `%Turn{}` — which did not carry `def_delta`
or `form`. So the Moves never reached the consumer that needed them, forcing it
back to snapshot-diffing / re-parsing.

Carry the two fields one hop down. Every turn-build site in the loop already
holds the per-run `lisp_step` and copies `lisp_step.memory`; `.def_delta` and
`.form` sit right beside it.

- `Turn` gains `:def_delta` + `:form` (+ `@type`); `Turn.success/5` and
  `Turn.failure/5` thread them out of `params`.
- `Metrics.build_turn/5` accepts `def_delta:`/`form:` opts into the params map.
- Every `Metrics.build_turn` caller with a `lisp_step` in scope passes
  `def_delta: lisp_step.def_delta, form: lisp_step.form` (loop.ex ×8,
  ptc_tool_call.ex ×6, runner.ex ×1). Synthetic/text-mode/budget turns with no
  run leave both `nil` — the honest signal for "fall back to a diff".

The load-bearing contract: folding the per-turn `def_delta`s (introduced ∪
changed, in order) reproduces `step.memory`. This is what lets the Hist cutover
(PLAN-008 SEAM 1) delete its `map_delta` snapshot-diff.

### Files touched

```
lib/ptc_runner/turn.ex                        — :def_delta + :form fields, @type, success/failure
lib/ptc_runner/sub_agent/loop/metrics.ex      — build_turn params: def_delta/form opts
lib/ptc_runner/sub_agent/loop.ex              — 8 build_turn callers pass lisp_step.def_delta/form
lib/ptc_runner/sub_agent/loop/ptc_tool_call.ex — 6 build_turn callers
lib/ptc_runner/sub_agent/runner.ex            — 1 build_turn caller
```

Tests: `test/ptc_runner/sub_agent/turn_move_propagation_test.exs` (3, incl. the
fold-equals-memory equivalence across a real multi-turn run).

## FEAT-002: expose `Handle.deep_realize/1` (single realization walker) ✅ LANDED

**Disposition**: spell-specific (PATCH-3 handle system), a clean public walker.

Two identical handle-realization deep-walkers existed: `Step.freeze/1`'s private
`freeze_term/1`, and `SpellAgent.Hist.Realize.walk/1` on the consumer side. The
consumer copy still raced the reaper, and the cont/tape path (not part of a
`%Step{}`) could not use `freeze`. Lift ONE walker into the runtime.

- `PtcRunner.Lisp.Handle.deep_realize/1` — deep-walk a term, realize every
  `%Handle{}` through its store (recursively), tombstone an unrealizable handle
  as `{:__frozen_unrealized__, reason, meta}`. `Handle.unrealized?/1` classifies.
- `Step.freeze/1` now delegates each field to `Handle.deep_realize/1`;
  `Step.unrealized?/1` delegates to `Handle.unrealized?/1`. Public contract of
  both is unchanged (existing MOVE-B tests pass verbatim).
- Lets `SpellAgent.Hist` delete its entire `Realize` module: the Step path uses
  `Step.freeze`, the cont/tape path calls `Handle.deep_realize` directly. One
  algorithm, one tombstone tag.

### Files touched

```
lib/ptc_runner/lisp/handle.ex  — deep_realize/1, unrealized?/1, tombstone type
lib/ptc_runner/step.ex          — freeze/1 + unrealized?/1 delegate to Handle
```

Tests: `test/ptc_runner/lisp/handle_deep_realize_test.exs` (8: bare/nested/
struct/recursive realize, evicted-term tombstone, identity on plain data).

