defmodule PtcRunner.Lisp.Handle do
  @moduledoc """
  Opaque handle to a large value parked OUTSIDE the sandbox heap (SPELL
  PATCH-3, D-2).

  ## The problem it solves

  A tool result is copied onto the calling sandbox process's heap the instant
  the Peer replies it (`GenServer.reply`). A 38MB org dashboard therefore
  blows the sandbox's `max_heap_size` *before* the program can project the
  three fields it actually wanted (BUG-426 / the E1 OOM class).

  ## The mechanism

  When a tool result exceeds a size threshold the Peer parks the term in a
  `PtcRunner.Lisp.HandleStore` process and hands the sandbox this struct
  instead — a few words. Handle-aware builtins (`count`, `get`, `get-in`,
  `keys`, `vals`, `select-keys`, `take`, `nth`, `first`, `contains?`) execute
  their projection IN the store process (where the term lives) and copy back
  ONLY the slice. Heap accounting then charges the program for what it
  computes on, never for what a tool happened to return.

  Critically NOT an ETS handle: `:ets.lookup` copies the whole term to the
  caller, which would re-land the 38MB on the sandbox heap and defeat the
  purpose. Projection must run where the term lives — hence a process, and a
  `GenServer.call` whose REPLY is the (small) slice.

  ## Self-describing

  The handle carries its own `store` reference, so a builtin can project (and
  re-park an oversized sub-result) without any ambient context. `meta` lets a
  program orient (`handle-meta`) without realizing the term: byte size, the
  shape (`:map` / `:list`), top-level `keys`, and `count`.
  """

  alias PtcRunner.Lisp.Keyword, as: LispKeyword

  @enforce_keys [:id, :store]
  defstruct [:id, :store, meta: %{}]

  @type t :: %__MODULE__{
          id: reference(),
          store: GenServer.server(),
          meta: map()
        }

  @doc "Whether a term is a parked-value handle."
  @spec handle?(term()) :: boolean()
  def handle?(%__MODULE__{}), do: true
  def handle?(_), do: false

  @typedoc """
  Marker left in place of a handle that could NOT be realized at write time
  (already evicted/tombstoned by the HandleStore reaper). Carries the failure
  reason and the handle's `meta` so a consumer can still orient on the dead
  binding instead of crashing.
  """
  @type tombstone :: {:__frozen_unrealized__, term(), map()}

  @doc """
  Deep-walk `term`, replacing every `%Handle{}` with its full realized value
  (recursively realized, since a realized value can itself nest handles).

  Recurses into maps (non-struct), lists, tuples, and the public fields of
  structs; non-handle leaves pass through unchanged. A handle that fails to
  realize (evicted/stale) degrades to a `t:tombstone/0`
  `{:__frozen_unrealized__, reason, meta}` rather than crashing the caller.

  This is the single handle-realization walker for the runtime: `Step.freeze/1`
  delegates to it, and external consumers (e.g. spell Hist's continuation tape)
  call it directly to materialize handles at the OWNER while the parked term is
  guaranteed live — before the HandleStore session bucket can cold-evict it.
  """
  @spec deep_realize(term()) :: term()
  def deep_realize(term) do
    cond do
      handle?(term) ->
        realize_handle(term)

      is_map(term) and not is_struct(term) ->
        Map.new(term, fn {k, v} -> {deep_realize(k), deep_realize(v)} end)

      is_struct(term) ->
        realize_struct(term)

      is_list(term) ->
        Enum.map(term, &deep_realize/1)

      is_tuple(term) ->
        term |> Tuple.to_list() |> Enum.map(&deep_realize/1) |> List.to_tuple()

      true ->
        term
    end
  end

  @doc "Whether `term` is a `deep_realize/1` unrealizable tombstone."
  @spec unrealized?(term()) :: boolean()
  def unrealized?({:__frozen_unrealized__, _reason, _meta}), do: true
  def unrealized?(_), do: false

  # A handle is realized THROUGH its store (its `store`/`id` are a pid/ref we
  # must never walk field-wise), then the materialized value is itself walked
  # (it may nest handles).
  defp realize_handle(%__MODULE__{meta: meta} = handle) do
    case PtcRunner.Lisp.HandleStore.realize(handle) do
      {:ok, term} -> deep_realize(term)
      {:error, reason} -> {:__frozen_unrealized__, reason, meta}
    end
  end

  # A non-Handle struct: realize its public fields, preserve the struct type.
  defp realize_struct(%mod{} = s) do
    s
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {k, deep_realize(v)} end)
    |> then(&struct(mod, &1))
  end

  @doc """
  Build the `meta` map describing `term` without retaining it. Cheap, shallow:
  byte size (flat, via `:erts_debug.flat_size` in words → bytes), shape, the
  top-level string keys for a map, and an element/k-v count.
  """
  @spec describe(term()) :: map()
  def describe(term) do
    base = %{"bytes" => approx_bytes(term)}

    cond do
      is_map(term) and not is_struct(term) ->
        Map.merge(base, %{
          "shape" => "map",
          "count" => map_size(term),
          "keys" => term |> Map.keys() |> Enum.map(&key_to_string/1) |> Enum.sort()
        })

      is_list(term) ->
        Map.merge(base, %{"shape" => "list", "count" => length(term)})

      true ->
        Map.put(base, "shape", "scalar")
    end
  end

  # `:erlang.external_size/1` — the serialized byte length, which (unlike
  # `:erts_debug.flat_size`) COUNTS sub-binary payloads. This matters: a tool
  # result like an org dashboard is mostly string bodies stored off-heap as
  # ref-counted binaries; `flat_size` undercounts it by orders of magnitude
  # (the exact BUG-426 payload), so it would never trip the park threshold.
  # external_size also tracks the real wire/JSON cost the handle avoids.
  defp approx_bytes(term), do: :erlang.external_size(term)

  defp key_to_string(%LispKeyword{name: name}), do: name
  defp key_to_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_to_string(k) when is_binary(k), do: k
  defp key_to_string(k), do: inspect(k)
end
