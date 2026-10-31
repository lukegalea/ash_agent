# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Board do
  @moduledoc """
  A fake outside service for the test host: a licensing board that takes notices about
  clinicians. It keeps what it accepted in an ETS table the test owns, so a test counts
  the calls that reached it and the notices it holds.

  `mode/1` sets how it answers the next calls:

    * `:accept`: it takes the notice and acknowledges it;
    * `:accept_then_lose`: it takes the notice, and the acknowledgement is lost on the
      way back (`{:error, %Error{reason: :timeout}}`): the effect happened, and the
      caller cannot tell;
    * `:busy`: it refuses before taking anything (`:rate_limited`);
    * `:refuse`: it refuses for good (`:refused`);
    * `:over_budget`: the caller's budget for it is spent (`:over_budget`);
    * `:accept_then_stale`: it takes the notice, and the caller's own write afterwards
      loses a race (`Ash.Error.Changes.StaleRecord`, an invalid-class error the board
      knows nothing about);
    * `:accept_then_raise`: it takes the notice, and the caller then raises.

  A notice sent with a key it has seen is not taken twice: the board deduplicates by the
  key, as an idempotent outside service does.
  """

  alias AshAgent.Test.Board.Error

  @table __MODULE__

  @doc "A fresh, empty board for this test, answering `:accept`."
  def start! do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])
    mode(:accept)
  end

  @doc "How the board answers from now on."
  def mode(mode), do: :ets.insert(@table, {:mode, mode})

  @doc "Posts a notice about `licence` under `key`."
  def post(licence, key) do
    :ets.update_counter(@table, :calls, 1, {:calls, 0})

    case :ets.lookup_element(@table, :mode, 2) do
      :busy ->
        {:error, Error.exception(reason: :rate_limited)}

      :refuse ->
        {:error, Error.exception(reason: :refused)}

      :over_budget ->
        {:error, Error.exception(reason: :over_budget)}

      mode ->
        :ets.insert_new(@table, {{:notice, key}, licence})

        answer(mode, key)
    end
  end

  defp answer(:accept_then_lose, _key), do: {:error, Error.exception(reason: :timeout)}

  defp answer(:accept_then_stale, _key),
    do: {:error, Ash.Error.Changes.StaleRecord.exception(resource: __MODULE__, filter: %{})}

  defp answer(:accept_then_raise, _key), do: raise("the caller fell over after the board")
  defp answer(_accept, key), do: {:ok, %{"ref" => key}}

  @doc "The notice under `key`, as the board's lookup answers it."
  def find(key) do
    case :ets.lookup(@table, {:notice, key}) do
      [{_, _licence}] ->
        {:ok, %{"outcome" => "succeeded", "effect_ref" => key, "effect_system" => "board"}}

      [] ->
        {:ok, %{"outcome" => "not_found"}}
    end
  end

  @doc "How many calls reached the board."
  def calls, do: :ets.lookup_element(@table, :calls, 2, 0)

  @doc "How many notices the board holds."
  def notices, do: :ets.select_count(@table, [{{{:notice, :_}, :_}, [], [true]}])
end
