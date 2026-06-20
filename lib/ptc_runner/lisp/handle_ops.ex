defmodule PtcRunner.Lisp.HandleOps do
  @moduledoc """
  Maps a builtin name + its arg list to a `HandleStore` projection tuple
  (SPELL PATCH-3, D-2), or `nil` if the builtin is not handle-projectable.

  This is the single registry of which builtins can run against a parked value
  WITHOUT realizing it. Each entry's arg shape mirrors the builtin's contract
  so the handle is a drop-in for the realized value. Anything not listed falls
  through to the realize-then-apply path in `Apply`.

  The projectable set is the NAVIGATION / SLICE surface — operations whose
  result is bounded by a small projection of the input, never the whole input:

      count  get  get-in  keys  vals  select-keys  contains?  first  nth  take

  Deliberately NOT projectable (W2a scope): transform-over-handle ops
  (`map`, `filter`, `group-by`, `sort-by`, `reduce`) whose closures would have
  to run inside the store process against an untrusted program. A program runs
  those by projecting to a slice first. (D-2 phase 2 / a future patch may add
  data-described transforms.)
  """

  @doc """
  Returns the projection tuple for `{name, args}` when the leading argument is
  the handle and the op is projectable, else `nil`.

  PTC-Lisp argument order puts the collection/map LAST for the seq ops
  (`(take n coll)`, `(nth coll i)`) but FIRST for the map ops (`(get m k)`),
  matching Clojure. We only project when the HANDLE is in the collection
  position; a handle anywhere else (e.g. as a `get` default) realizes normally.
  """
  @spec projection(atom(), [term()]) :: tuple() | nil
  # map ops — handle is the first arg (the map)
  def projection(:count, [%handle_mod{}]) when handle_mod == PtcRunner.Lisp.Handle,
    do: {:count}

  def projection(:get, [%PtcRunner.Lisp.Handle{}, key]), do: {:get, key, nil}
  def projection(:get, [%PtcRunner.Lisp.Handle{}, key, default]), do: {:get, key, default}
  def projection(:"get-in", [%PtcRunner.Lisp.Handle{}, path]), do: {:get_in, path, nil}

  def projection(:"get-in", [%PtcRunner.Lisp.Handle{}, path, default]),
    do: {:get_in, path, default}

  def projection(:keys, [%PtcRunner.Lisp.Handle{}]), do: {:keys}
  def projection(:vals, [%PtcRunner.Lisp.Handle{}]), do: {:vals}
  def projection(:"select-keys", [%PtcRunner.Lisp.Handle{}, ks]), do: {:select_keys, ks}
  def projection(:contains?, [%PtcRunner.Lisp.Handle{}, key]), do: {:contains?, key}
  def projection(:first, [%PtcRunner.Lisp.Handle{}]), do: {:first}

  # seq ops — handle is the LAST arg (the collection)
  def projection(:take, [n, %PtcRunner.Lisp.Handle{}]), do: {:take, n}
  def projection(:nth, [%PtcRunner.Lisp.Handle{}, idx]), do: {:nth, idx, nil}
  def projection(:nth, [%PtcRunner.Lisp.Handle{}, idx, default]), do: {:nth, idx, default}

  def projection(_name, _args), do: nil
end
