# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Output do
  @moduledoc """
  A run's answer, cast to its version's `output_type`.

  The type is named as `AshAgent.Agent.content/1` stores it: a built-in short name
  (`"string"`, `"map"`, `"integer"`) or a type module's name. A `:string` answer is the
  model's text, trimmed, and must not be empty. Any other answer is read as JSON (a
  fenced block is unwrapped) when it parses, as the text itself otherwise, then cast
  with `Ash.Type.cast_input/3` and checked with `Ash.Type.apply_constraints/3`. The
  stored output is `%{"value" => value}`, dumped as the type embeds it.

  An answer that does not cast is given back to the model with what was wrong
  (`repair_prompt/2`), a bounded number of times (the version's `max_repairs`).
  """

  @doc "The Ash type `name` stands for, or why there is none."
  @spec type(String.t() | nil) :: {:ok, Ash.Type.t()} | {:error, String.t()}
  def type(name) when is_binary(name) do
    atom =
      if String.match?(name, ~r/^[A-Z]/),
        do: String.to_existing_atom("Elixir." <> name),
        else: String.to_existing_atom(name)

    type = Ash.Type.get_type(atom)

    if Ash.Type.ash_type?(type),
      do: {:ok, type},
      else: {:error, "output_type #{name} is not an Ash type"}
  rescue
    ArgumentError -> {:error, "output_type #{name} is not an Ash type"}
  end

  def type(_name), do: {:error, "output_type is not set"}

  @doc "`text` cast to the type named `name`: `{:ok, %{\"value\" => value}}` or `{:error, reason}`."
  @spec cast(String.t() | nil, String.t()) :: {:ok, map()} | {:error, String.t()}
  def cast(text, name) do
    with {:ok, type} <- type(name),
         {:ok, value} <- cast_value(type, String.trim(text || "")),
         {:ok, value} <- Ash.Type.apply_constraints(type, value, []),
         {:ok, dumped} <- Ash.Type.dump_to_embedded(type, value, []) do
      {:ok, %{"value" => dumped}}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, describe(reason)}
      :error -> {:error, "it is not a valid #{name}"}
    end
  end

  @doc "The message that asks the model to answer again, saying what was wrong."
  @spec repair_prompt(String.t(), String.t()) :: String.t()
  def repair_prompt(reason, name) do
    "Your answer could not be read as #{name}: #{reason}. " <>
      "Answer again with only #{shape(name)}, and nothing else."
  end

  defp cast_value(_type, ""), do: {:error, "the answer is empty"}
  defp cast_value(Ash.Type.String, text), do: {:ok, text}

  defp cast_value(type, text) do
    value =
      case Jason.decode(unfence(text)) do
        {:ok, decoded} -> decoded
        {:error, _not_json} -> text
      end

    case Ash.Type.cast_input(type, value, []) do
      {:ok, nil} -> {:error, "the answer is empty"}
      {:ok, cast} -> {:ok, cast}
      {:error, error} -> {:error, describe(error)}
      :error -> :error
    end
  end

  defp unfence(text) do
    case Regex.run(~r/\A```[a-zA-Z]*\s*\n(.*)\n```\z/s, text) do
      [_, inner] -> String.trim(inner)
      nil -> text
    end
  end

  defp shape("string"), do: "the answer as text"
  defp shape("map"), do: "one JSON object"
  defp shape(name), do: "the #{name}, as JSON"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{__exception__: true} = error), do: Exception.message(error)

  defp describe(reason) when is_list(reason) do
    if Keyword.keyword?(reason),
      do: to_string(reason[:message] || "it is not valid"),
      else: Enum.map_join(reason, "; ", &describe/1)
  end

  defp describe(reason) when is_map(reason),
    do: to_string(Map.get(reason, :message) || Map.get(reason, "message") || "it is not valid")

  defp describe(reason), do: inspect(reason)
end
