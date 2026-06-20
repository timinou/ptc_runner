defmodule PtcRunner.Lisp.HandleStore do
  @moduledoc """
  Process that OWNS large parked values for `PtcRunner.Lisp.Handle` (SPELL
  PATCH-3, D-2).

  The store holds terms that must never land on a sandbox heap. Every
  projection (`count`, `get`, `take`, ...) runs HERE, in the owner process,
  via a `GenServer.call` whose reply is the (small) slice — so the big term is
  copied exactly once into this process at `put`, and thereafter only slices
  leave it. `:ets`-style lookup would copy the whole term back to the caller
  and defeat the purpose.

  ## Lifetime / GC

  Values are bucketed by an opaque `exec_id` (the originating execute). One
  `release(exec_id)` at execute teardown drops every term that execute parked
  — a single sweep, no per-handle bookkeeping by the program. The store is a
  long-lived singleton (one per BEAM node, started under the runtime
  supervisor); buckets, not the process, are the unit of cleanup.

  ## Session-store reaper (PATCH-5)

  The session bucket (`@session_bucket`, SPELL PATCH-4) is NEVER released by
  an execute teardown — values parked there survive indefinitely. Without a
  ceiling, a long session (or W4 unattended re-execution) leaks unbounded
  heap. The reaper adds:

  - **Last-access timestamps**: a parallel `access_ts` map tracks
    `System.monotonic_time(:millisecond)` per session-bucket term id,
    updated on every project/realize/rehome touch.
  - **Eviction**: on `put`/`rehome` INTO the session bucket, after inserting,
    while total `:erlang.external_size` exceeds the ceiling, the COLDEST
    session-bucket term(s) are evicted until under ceiling.
  - **Tombstone set**: evicted ids are retained in a bounded `evicted`
    MapSet (max 100) so a later read of an evicted binding can be
    distinguished from a never-existed one.
  - **Ceiling**: configurable via `configure/2`; default 64 MB. Exec buckets
    are unaffected — they keep their single-sweep release.
  """
  use GenServer

  alias PtcRunner.Lisp.Handle
  alias PtcRunner.Lisp.Runtime

  @default_name __MODULE__

  # The persistent session bucket (SPELL PATCH-4, D-6). Never released by an
  # execute teardown; only the LRU reaper (PATCH-5) evicts from it.
  @session_bucket :__session_bindings__

  # Default session-store ceiling (64 MB in bytes). A session bucket of parked
  # bindings (PATCH-4) grows unbounded without this reaper.
  @default_session_store_bytes 64 * 1024 * 1024

  # Maximum number of evicted ids retained in the tombstone set. Once bound,
  # the oldest eviction record is dropped per new eviction — never a tombstone
  # leak. Retained long enough for a cold binding read to distinguish "was
  # evicted" from "never existed."
  @max_evicted_ids 100

  # A projection result at or above this serialized size (BYTES) is itself
  # re-parked as a nested handle rather than copied to the caller. Mirrors the
  # Peer's park threshold; keeps `(get big-handle "a-huge-field")` from
  # re-OOMing. `:erlang.external_size/1` counts binary payloads (the org-body
  # case), unlike `flat_size`.
  @repark_bytes 262_144

  # ----- client API -----

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Park `term` under `exec_id` and return a `Handle` describing it. The handle's
  `store` is `server`, so later projections route back here with no context.
  """
  @spec put(GenServer.server(), term(), term()) :: Handle.t()
  def put(server \\ @default_name, term, exec_id) do
    meta = Handle.describe(term)
    id = GenServer.call(server, {:put, term, exec_id})
    %Handle{id: id, store: server, meta: meta}
  end

  @doc """
  Set the session-store ceiling (in BYTES). The reaper evicts the coldest
  session-bucket term(s) when parked bytes exceed this ceiling. Pass `nil` to
  reset to the default (64 MB). Idempotent and safe to call at any point.
  """
  @spec configure(GenServer.server(), non_neg_integer() | nil) :: :ok
  def configure(server \\ @default_name, ceiling_bytes) do
    GenServer.call(server, {:configure, ceiling_bytes})
  end

  @doc """
  Returns `true` if `id` was evicted from the session bucket (was a valid term
  that the reaper removed). Returns `false` if the id is unknown or was never
  in the session bucket. Used by the Peer to distinguish "evicted" from
  "released" or "never existed."
  """
  @spec was_evicted?(GenServer.server(), term()) :: boolean()
  def was_evicted?(server \\ @default_name, id) do
    GenServer.call(server, {:was_evicted, id})
  end

  @doc """
  Run a projection (described as data) against the term behind `handle`,
  returning the slice. An oversized slice is re-parked under the same
  `exec_id` and returned as a nested handle.

  Returns `{:ok, value}` or `{:error, :stale_handle}` if the term was already
  released (e.g. a handle escaped its execute). Returns
  `{:error, {:evicted, id}}` if the term was evicted from the session bucket
  (PATCH-5).
  """
  @spec project(Handle.t(), tuple(), term()) ::
          {:ok, term()} | {:error, :stale_handle} | {:error, {:evicted, term()}}
  def project(%Handle{id: id, store: store}, projection, exec_id) do
    GenServer.call(store, {:project, id, projection, exec_id})
  end

  @doc """
  Materialize the full term behind a handle (the escape hatch / final realize).
  Returns `{:ok, term}`, `{:error, :stale_handle}`, or
  `{:error, {:evicted, id}}`.
  """
  @spec realize(Handle.t()) ::
          {:ok, term()} | {:error, :stale_handle} | {:error, {:evicted, term()}}
  def realize(%Handle{id: id, store: store}) do
    GenServer.call(store, {:realize, id})
  end

  @doc "Drop every term parked under `exec_id`. Idempotent."
  @spec release(GenServer.server(), term()) :: :ok
  def release(server \\ @default_name, exec_id) do
    GenServer.cast(server, {:release, exec_id})
  end

  @doc """
  Move the term behind `handle` from its current bucket into `target_exec_id`
  (SPELL PATCH-4, D-6) and return a fresh handle bound there. Used to re-home a
  bound large value into the persistent session bucket before its per-execute
  bucket is released — the binding survives as a small handle, not a realized
  term. The term is NOT copied (it stays in the store); only its bucket tag
  changes. Stale handle → `{:error, :stale_handle}`.
  """
  @spec rehome(GenServer.server(), Handle.t(), term()) ::
          {:ok, Handle.t()} | {:error, :stale_handle}
  def rehome(server \\ @default_name, %Handle{id: id, meta: meta}, target_exec_id) do
    case GenServer.call(server, {:rehome, id, target_exec_id}) do
      {:ok, new_id} -> {:ok, %Handle{id: new_id, store: server, meta: meta}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Cost stats for an execute's parked values (SPELL PATCH-3 / W2b, D-7):
  `%{count: n, bytes: total_serialized_bytes}`. Lets the Peer surface how much
  a program offloaded — the observable proof that handles kept N bytes off the
  sandbox heap. Returns zeros for an unknown/empty exec_id.
  """
  @spec stats(GenServer.server(), term()) :: %{count: non_neg_integer(), bytes: non_neg_integer()}
  def stats(server \\ @default_name, exec_id) do
    GenServer.call(server, {:stats, exec_id})
  end

  # ----- server -----

  @impl true
  def init(_) do
    {:ok,
     %{
       terms: %{},
       by_exec: %{},
       # PATCH-5 LRU reaper state
       access_ts: %{},
       session_bytes: 0,
       session_ceiling: @default_session_store_bytes,
       evicted: MapSet.new()
     }}
  end

  # ----- handle_call: configure -----

  @impl true
  def handle_call({:configure, ceiling_bytes}, _from, state) do
    ceiling =
      if is_integer(ceiling_bytes) and ceiling_bytes > 0,
        do: ceiling_bytes,
        else: @default_session_store_bytes

    {:reply, :ok, %{state | session_ceiling: ceiling}}
  end

  # ----- handle_call: was_evicted -----

  def handle_call({:was_evicted, id}, _from, state) do
    {:reply, MapSet.member?(state.evicted, id), state}
  end

  # ----- handle_call: put -----

  def handle_call({:put, term, exec_id}, _from, state) do
    id = make_ref()
    terms = Map.put(state.terms, id, {term, exec_id})
    by_exec = Map.update(state.by_exec, exec_id, [id], &[id | &1])

    {access_ts, session_bytes, evicted, terms, by_exec} =
      if exec_id == @session_bucket do
        size = :erlang.external_size(term)
        now = System.monotonic_time(:millisecond)
        access_ts = Map.put(state.access_ts, id, now)
        session_bytes = state.session_bytes + size
        evict_if_over_ceiling(session_bytes, state.session_ceiling, id,
          access_ts, terms, by_exec, state.evicted)
      else
        {state.access_ts, state.session_bytes, state.evicted, terms, by_exec}
      end

    {:reply, id,
     %{state | terms: terms, by_exec: by_exec,
       access_ts: access_ts, session_bytes: session_bytes, evicted: evicted}}
  end

  # ----- handle_call: project -----

  def handle_call({:project, id, projection, exec_id}, _from, state) do
    case Map.fetch(state.terms, id) do
      {:ok, {term, owner}} ->
        state = touch(state, id, owner)
        result = apply_projection(term, projection)
        {reply, state} = maybe_repark(result, exec_id, state)
        {:reply, {:ok, reply}, state}

      :error ->
        {:reply, eviction_error_or_stale(id, state), state}
    end
  end

  # ----- handle_call: realize -----

  def handle_call({:realize, id}, _from, state) do
    case Map.fetch(state.terms, id) do
      {:ok, {term, owner}} ->
        state = touch(state, id, owner)
        {:reply, {:ok, term}, state}

      :error ->
        {:reply, eviction_error_or_stale(id, state), state}
    end
  end

  # ----- handle_call: rehome -----

  def handle_call({:rehome, id, target_exec_id}, _from, state) do
    case Map.fetch(state.terms, id) do
      {:ok, {term, owner}} ->
        new_id = make_ref()
        size = :erlang.external_size(term)

        # Phase 1: remove old id from terms, its bucket, and access_ts if session.
        terms = Map.delete(state.terms, id)
        by_exec = drop_from_bucket(state.by_exec, owner, id)
        {access_ts, session_bytes} =
          if owner == @session_bucket do
            {Map.delete(state.access_ts, id), state.session_bytes - size}
          else
            {state.access_ts, state.session_bytes}
          end

        # Phase 2: insert new id under target bucket.
        terms = Map.put(terms, new_id, {term, target_exec_id})
        by_exec = Map.update(by_exec, target_exec_id, [new_id], &[new_id | &1])

        {access_ts, session_bytes, evicted, terms, by_exec} =
          if target_exec_id == @session_bucket do
            now = System.monotonic_time(:millisecond)
            access_ts = Map.put(access_ts, new_id, now)
            session_bytes = session_bytes + size
            evict_if_over_ceiling(session_bytes, state.session_ceiling, new_id,
              access_ts, terms, by_exec, state.evicted)
          else
            {access_ts, session_bytes, state.evicted, terms, by_exec}
          end

        {:reply, {:ok, new_id},
         %{state | terms: terms, by_exec: by_exec,
           access_ts: access_ts, session_bytes: session_bytes, evicted: evicted}}

      :error ->
        {:reply, eviction_error_or_stale(id, state), state}
    end
  end

  # ----- handle_call: stats -----

  def handle_call({:stats, exec_id}, _from, state) do
    ids = Map.get(state.by_exec, exec_id, [])

    bytes =
      Enum.reduce(ids, 0, fn id, acc ->
        case Map.fetch(state.terms, id) do
          {:ok, {term, _owner}} -> acc + :erlang.external_size(term)
          :error -> acc
        end
      end)

    {:reply, %{count: length(ids), bytes: bytes}, state}
  end

  # ----- handle_cast: release -----

  @impl true
  def handle_cast({:release, exec_id}, state) do
    {ids, by_exec} = Map.pop(state.by_exec, exec_id, [])
    terms = Map.drop(state.terms, ids)

    # If releasing the session bucket (should not happen in normal operation,
    # but handle gracefully), also clear LRU tracking.
    {access_ts, session_bytes} =
      if exec_id == @session_bucket do
        {%{}, 0}
      else
        {state.access_ts, state.session_bytes}
      end

    {:noreply,
     %{state | terms: terms, by_exec: by_exec,
       access_ts: access_ts, session_bytes: session_bytes}}
  end

  # ----- private: touch-on-access -----

  # Update the last-access timestamp for a session-bucket term. Exec-bucket
  # terms are not tracked — the release/1 sweep is their GC.
  defp touch(state, id, @session_bucket) do
    %{state | access_ts: Map.put(state.access_ts, id, System.monotonic_time(:millisecond))}
  end

  defp touch(state, _id, _owner), do: state

  # ----- private: eviction -----

  # While total session-bucket bytes exceed the ceiling, evict the coldest
  # term(s). `just_inserted_id` is excluded so the just-parked value survives
  # its own insertion.
  defp evict_if_over_ceiling(session_bytes, ceiling, just_inserted_id,
        access_ts, terms, by_exec, evicted) do
    if session_bytes <= ceiling do
      {access_ts, session_bytes, evicted, terms, by_exec}
    else
      candidates = Enum.filter(access_ts, fn {id, _ts} -> id != just_inserted_id end)

      case Enum.min_by(candidates, fn {_id, ts} -> ts end, fn -> nil end) do
        nil ->
          {access_ts, session_bytes, evicted, terms, by_exec}

        {evict_id, _ts} ->
          case Map.fetch(terms, evict_id) do
            {:ok, {evict_term, bucket}} ->
              evict_size = :erlang.external_size(evict_term)
              new_session_bytes = session_bytes - evict_size

              new_terms = Map.delete(terms, evict_id)
              new_by_exec = drop_from_bucket(by_exec, bucket, evict_id)
              new_access_ts = Map.delete(access_ts, evict_id)

              # Bounded evicted set: FIFO drop when over @max_evicted_ids
              new_evicted =
                if MapSet.size(evicted) >= @max_evicted_ids do
                  [_oldest | rest] = MapSet.to_list(evicted)
                  rest |> MapSet.new() |> MapSet.put(evict_id)
                else
                  MapSet.put(evicted, evict_id)
                end

              evict_if_over_ceiling(new_session_bytes, ceiling, just_inserted_id,
                new_access_ts, new_terms, new_by_exec, new_evicted)

            :error ->
              evict_if_over_ceiling(session_bytes, ceiling, just_inserted_id,
                Map.delete(access_ts, evict_id), terms, by_exec, evicted)
          end
      end
    end
  end

  # Return a stale-or-evicted error for an id not found in `terms`.
  defp eviction_error_or_stale(id, state) do
    if MapSet.member?(state.evicted, id) do
      {:error, {:evicted, id}}
    else
      {:error, :stale_handle}
    end
  end

  # Remove `id` from its `bucket`'s membership list, dropping the bucket key
  # entirely when it empties (so it never accumulates stale empty lists).
  defp drop_from_bucket(by_exec, bucket, id) do
    case Map.get(by_exec, bucket) do
      nil ->
        by_exec

      ids ->
        case List.delete(ids, id) do
          [] -> Map.delete(by_exec, bucket)
          remaining -> Map.put(by_exec, bucket, remaining)
        end
    end
  end

  # ----- projections (run in the owner process; reply is the slice) -----
  #
  # Each clause mirrors the corresponding PTC-Lisp builtin's semantics so a
  # handle is a drop-in for the realized value. Delegates to `Runtime` (the
  # same functions the builtins call) where possible, so behaviour can't drift.

  defp apply_projection(term, {:count}) do
    cond do
      is_map(term) and not is_struct(term) -> map_size(term)
      is_list(term) -> length(term)
      is_binary(term) -> String.length(term)
      true -> 0
    end
  end

  defp apply_projection(term, {:get, key, default}), do: Runtime.get(term, key, default)
  defp apply_projection(term, {:get_in, path, default}), do: Runtime.get_in(term, path, default)
  defp apply_projection(term, {:keys}), do: Runtime.keys(term)
  defp apply_projection(term, {:vals}), do: Runtime.vals(term)
  defp apply_projection(term, {:select_keys, keys}), do: Runtime.select_keys(term, keys)
  defp apply_projection(term, {:contains?, key}), do: Runtime.contains?(term, key)
  defp apply_projection(term, {:first}), do: Runtime.first(term)
  defp apply_projection(term, {:nth, idx, default}), do: nth(term, idx, default)

  defp apply_projection(term, {:take, n}) when is_list(term), do: Enum.take(term, n)

  defp apply_projection(term, {:take, n}) when is_map(term) and not is_struct(term),
    do: term |> Enum.take(n) |> Map.new()

  # `(take n string)` yields a char list in PTC-Lisp; mirror that for a parked
  # binary so a large-string handle behaves like the realized value.
  defp apply_projection(term, {:take, n}) when is_binary(term),
    do: term |> String.graphemes() |> Enum.take(n)

  defp apply_projection(_term, {:take, _n}), do: []

  defp nth(list, idx, default) when is_list(list), do: Enum.at(list, idx, default)
  defp nth(_other, _idx, default), do: default

  # Re-park an oversized projection result so `(get big-handle "fat-field")`
  # cannot re-OOM the sandbox. Small results pass through verbatim. Handles and
  # scalars are never re-parked.
  defp maybe_repark(%Handle{} = h, _exec_id, state), do: {h, state}

  defp maybe_repark(result, exec_id, state)
       when is_map(result) or is_list(result) do
    if :erlang.external_size(result) >= @repark_bytes do
      id = make_ref()
      terms = Map.put(state.terms, id, {result, exec_id})
      by_exec = Map.update(state.by_exec, exec_id, [id], &[id | &1])
      handle = %Handle{id: id, store: self_name(), meta: Handle.describe(result)}
      {handle, %{state | terms: terms, by_exec: by_exec}}
    else
      {result, state}
    end
  end

  defp maybe_repark(result, _exec_id, state), do: {result, state}

  # The registered name (handles must carry a server reference that survives
  # leaving this process; the singleton is name-registered).
  defp self_name do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _ -> self()
    end
  end
end
