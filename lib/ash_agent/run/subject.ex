# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Subject do
  @moduledoc """
  The record a run is about, read as the actor who starts the run.

  `subject_type` names an Ash resource by its module name and `subject_id` its primary
  key. Both or neither: a run about nothing in particular names neither.
  """

  @doc """
  Reads the subject named by `type` and `id` with `opts` (the actor, the tenant and
  whether to authorize, as the start runs).

  `{:ok, nil}` when neither is given; `{:error, field, message}` when only one is, when
  `type` names no Ash resource with a single primary key, or when the actor cannot read
  the record. A record that is not there and one the actor may not read are refused
  alike.
  """
  @spec read(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, Ash.Resource.record() | nil} | {:error, atom(), String.t()}
  def read(nil, nil, _opts), do: {:ok, nil}
  def read(nil, _id, _opts), do: {:error, :subject_type, "is required with subject_id"}
  def read(_type, nil, _opts), do: {:error, :subject_id, "is required with subject_type"}

  def read(type, id, opts) do
    with {:ok, resource} <- resource(type) do
      case Ash.get(resource, id, Keyword.take(opts, [:actor, :tenant, :authorize?, :tracer])) do
        {:ok, subject} -> {:ok, subject}
        {:error, _not_readable} -> {:error, :subject_id, "is not a record the actor can read"}
      end
    end
  end

  # Law: never create an atom from a caller's string. A subject's resource is code that
  # is already loaded, so its module atom already exists.
  defp resource(type) do
    module = String.to_existing_atom("Elixir." <> type)

    case Ash.Resource.Info.resource?(module) && Ash.Resource.Info.primary_key(module) do
      [_single] -> {:ok, module}
      _not_one -> not_a_subject(type)
    end
  rescue
    ArgumentError -> not_a_subject(type)
  end

  defp not_a_subject(type),
    do: {:error, :subject_type, "#{type} is not an Ash resource with a single primary key"}
end
