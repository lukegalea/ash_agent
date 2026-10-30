# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Target do
  @moduledoc """
  The action an invocation runs: how its name resolves, how its arguments are checked
  before it runs, and how it is run.

  ## Naming

  A target is written `"<resource module>.<action>"`, for example
  `"MyClinic.Credentials.Credential.activate"`. It resolves only to a resource module that
  is already loaded, to one of its actions, and only if that action has an effects
  declaration (`AshAgent.Effects`): a target with no declaration cannot be governed,
  because nothing says whether it needs approval or reaches outside the application.

  ## Arguments

  `args` is a map of the action's inputs, as JSON would carry them. For an update or a
  destroy it also carries the subject's primary key (`"id"` for most resources), which
  names the record and is not an input. `prepare/3` checks them without running the
  action or any of its changes: every key is an input or the primary key, every value
  casts to its input's type, every required argument is present, and the subject exists.
  """

  alias AshAgent.Effects.Effect
  alias AshAgent.Invocation.{Dispatch, SubjectUnreachable}

  @typedoc "A resolved target."
  @type t :: %{
          resource: Ash.Resource.t(),
          action: Ash.Resource.Actions.action(),
          effect: Effect.t()
        }

  @doc "Resolves `name` to its resource, action and effects declaration."
  @spec resolve(String.t()) :: {:ok, t()} | {:error, String.t()}
  def resolve(name) when is_binary(name) do
    with [module_name, action_name] <- split(name),
         {:ok, resource} <- resource(module_name),
         {:ok, action} <- action(resource, action_name),
         {:ok, effect} <- effect(resource, action) do
      {:ok, %{resource: resource, action: action, effect: effect}}
    else
      :error ->
        {:error, "#{inspect(name)} is not a target: write it as \"Resource.Module.action\""}

      {:error, message} ->
        {:error, message}
    end
  end

  def resolve(name), do: {:error, "#{inspect(name)} is not a target name"}

  @doc "The target name of `action` on `resource`."
  @spec name(Ash.Resource.t(), atom()) :: String.t()
  def name(resource, action), do: "#{inspect(resource)}.#{action}"

  @doc """
  The target's digest: SHA-256 over the canonical JSON of its input schema, as ash_ai
  renders it for a model, and its effects declaration. A change to either changes it.
  """
  @spec digest(t()) :: String.t()
  def digest(%{resource: resource, action: action, effect: effect}) do
    AshAgent.Digest.sha256_hex(%{
      "input_schema" => AshAi.Tool.Schema.for_action(nil, resource, action),
      "effects" => Effect.to_map(effect)
    })
  end

  @doc """
  Checks `args` against the target's inputs without running it.

  Returns `{:ok, prepared}` with the cast inputs and, for an update or a destroy, the
  subject record, or `{:error, messages}`.

  The subject is read as the caller: `opts` carry the request's `actor`, `tenant`,
  `authorize?` and `context`. A record the caller cannot read gets the same message as
  one that does not exist, so a request tells its caller nothing about records outside
  what they may read, not even whether one exists. Whether the executing principal may
  act on the subject is decided again when the target runs.
  """
  @spec prepare(t(), map(), keyword()) ::
          {:ok, %{inputs: map(), subject: Ash.Resource.record() | nil}} | {:error, [String.t()]}
  def prepare(%{resource: resource, action: action}, args, opts) when is_map(args) do
    args = Map.new(args, fn {key, value} -> {to_string(key), value} end)
    {pk, inputs} = Map.split(args, primary_key_names(resource, action))

    with {:ok, cast} <- cast_inputs(resource, action, inputs),
         {:ok, subject} <- subject(resource, action, pk, opts) do
      {:ok, %{inputs: cast, subject: subject}}
    end
  end

  def prepare(_target, _args, _opts), do: {:error, ["args must be a map"]}

  @doc """
  The preconditions captured with a request: the subject's `version_number`, when the
  subject has one. An approval bound to them goes stale when the subject changes.
  """
  @spec preconditions(t(), Ash.Resource.record() | nil) :: [map()]
  def preconditions(_target, nil), do: []

  def preconditions(%{resource: resource}, subject) do
    if Ash.Resource.Info.attribute(resource, :version_number) do
      [
        %{
          "resource" => inspect(resource),
          "id" => primary_key_string(resource, subject),
          "version_number" => subject.version_number
        }
      ]
    else
      []
    end
  end

  @doc """
  `preconditions` as their records stand now: each entry with its record's current
  `version_number`, or `nil` when the record is gone. Read without authorization, in
  `opts[:tenant]`: the machinery checking what a request depends on, not a person
  reading.
  """
  @spec current_preconditions([map()], keyword()) :: [map()]
  def current_preconditions(preconditions, opts) do
    Enum.map(preconditions, fn %{"resource" => name, "id" => id} = precondition ->
      Map.put(precondition, "version_number", current_version(name, id, opts))
    end)
  end

  defp current_version(name, id, opts) do
    with {:ok, resource} <- resource(name),
         names = Ash.Resource.Info.primary_key(resource),
         values = String.split(id, ",", parts: length(names)),
         {:ok, %{version_number: version}} <-
           resource
           |> Ash.Query.do_filter(Enum.zip(names, values))
           |> Ash.read_one(tenant: opts[:tenant], authorize?: false) do
      version
    else
      _gone -> nil
    end
  end

  @doc """
  Runs the target with `args` as `opts[:actor]`, authorized, and returns a JSON-ready
  summary of what it returned, or the `AshAgent.Invocation.Dispatch` it returned when it
  handed the work on. `opts` are passed to the action (`actor`, `tenant`, `context`).
  """
  @spec run(t(), map(), keyword()) :: {:ok, map() | Dispatch.t()} | {:error, term()}
  def run(%{resource: resource, action: action}, args, opts) do
    args = Map.new(args, fn {key, value} -> {to_string(key), value} end)
    {pk, inputs} = Map.split(args, primary_key_names(resource, action))
    opts = Keyword.put(opts, :authorize?, true)

    resource
    |> run_action(action, pk, inputs, opts)
    |> case do
      {:ok, %Dispatch{} = dispatch} -> {:ok, dispatch}
      {:ok, value} -> {:ok, summarize(value)}
      :ok -> {:ok, %{}}
      {:error, error} -> {:error, error}
    end
  end

  @typedoc "What a target's `reconcile_with` action found."
  @type found :: %{
          outcome: :succeeded | :not_found | :unknown,
          effect_ref: String.t() | nil,
          effect_system: String.t() | nil
        }

  @doc """
  Runs the target's `reconcile_with` action, as `opts[:actor]` and authorized, to find
  out whether the effect of a call whose outcome was lost happened.

  The action gets those of `args` that are its inputs, plus `invocation_key` when it has
  an input of that name (an outside service that took the key as its idempotency key
  can be asked by it); `opts[:context]` carries the invocation under `:ash_agent`, as for
  the target. What it returns is read as:

    * a `:read` action: a record found means the effect happened, and its primary key is
      the effect's reference; none found means it did not;
    * a generic action: `:succeeded`, `:not_found` or `:unknown` (as an atom or a
      string), or a map with that as `outcome` and optionally `effect_ref` and
      `effect_system`. Anything else is `:unknown`.

  `{:error, :no_reconcile_with}` when the target declares none.
  """
  @spec lookup(t(), String.t(), map(), keyword()) :: {:ok, found()} | {:error, term()}
  def lookup(%{resource: resource, effect: %{reconcile_with: name}}, key, args, opts)
      when not is_nil(name) do
    action = Ash.Resource.Info.action(resource, name)
    inputs = lookup_inputs(resource, action, key, args)
    opts = Keyword.put(opts, :authorize?, true)

    case action.type do
      :read ->
        resource
        |> Ash.Query.for_read(name, inputs, opts)
        |> Ash.Query.limit(1)
        |> Ash.read()
        |> case do
          {:ok, [record | _]} ->
            {:ok, found(:succeeded, primary_key_string(resource, record), nil)}

          {:ok, []} ->
            {:ok, found(:not_found, nil, nil)}

          {:error, error} ->
            {:error, error}
        end

      :action ->
        resource
        |> Ash.ActionInput.for_action(name, inputs, opts)
        |> Ash.run_action()
        |> case do
          {:ok, value} -> {:ok, interpret(value)}
          {:error, error} -> {:error, error}
        end
    end
  end

  def lookup(_target, _key, _args, _opts), do: {:error, :no_reconcile_with}

  defp lookup_inputs(resource, action, key, args) do
    fields = input_fields(resource, action)
    args = Map.new(args, fn {name, value} -> {to_string(name), value} end)

    args
    |> Map.take(Map.keys(fields))
    |> then(fn inputs ->
      if Map.has_key?(fields, "invocation_key"),
        do: Map.put(inputs, "invocation_key", key),
        else: inputs
    end)
  end

  defp interpret(%{} = found) do
    get = fn name -> Map.get(found, name, Map.get(found, to_string(name))) end
    found(outcome(get.(:outcome)), string(get.(:effect_ref)), string(get.(:effect_system)))
  end

  defp interpret(outcome), do: found(outcome(outcome), nil, nil)

  defp outcome(outcome) when outcome in [:succeeded, "succeeded"], do: :succeeded
  defp outcome(outcome) when outcome in [:not_found, "not_found"], do: :not_found
  defp outcome(_outcome), do: :unknown

  defp found(outcome, ref, system),
    do: %{outcome: outcome, effect_ref: ref, effect_system: system}

  defp string(nil), do: nil
  defp string(value), do: to_string(value)

  defp run_action(resource, %{type: :create, name: name}, _pk, inputs, opts) do
    resource |> Ash.Changeset.for_create(name, inputs, opts) |> Ash.create()
  end

  defp run_action(resource, %{type: :update, name: name}, pk, inputs, opts) do
    with {:ok, record} <- reach(resource, pk, opts) do
      record |> Ash.Changeset.for_update(name, inputs, opts) |> Ash.update()
    end
  end

  defp run_action(resource, %{type: :destroy, name: name}, pk, inputs, opts) do
    with {:ok, record} <- reach(resource, pk, opts) do
      record
      |> Ash.Changeset.for_destroy(name, inputs, opts)
      |> Ash.destroy(return_destroyed?: true)
    end
  end

  defp run_action(resource, %{type: :action, name: name}, _pk, inputs, opts) do
    resource |> Ash.ActionInput.for_action(name, inputs, opts) |> Ash.run_action()
  end

  defp run_action(resource, %{type: :read, name: name}, _pk, inputs, opts) do
    resource |> Ash.Query.for_read(name, inputs, opts) |> Ash.read()
  end

  defp get(resource, pk, opts) do
    resource
    |> Ash.Query.do_filter(pk_filter(resource, pk))
    |> Ash.read_one(Keyword.take(opts, [:actor, :tenant, :authorize?, :context]))
    |> case do
      {:ok, nil} -> {:error, Ash.Error.Query.NotFound.exception(resource: resource)}
      other -> other
    end
  end

  # The subject as the running actor reads it. When they cannot, whether the record is
  # still there decides the refusal: gone is a request that no longer fits (`NotFound`,
  # invalid), there but out of reach is the actor refused (`SubjectUnreachable`,
  # forbidden). Only the executor sees which; the request never learns more than that the
  # run failed.
  defp reach(resource, pk, opts) do
    case get(resource, pk, opts) do
      {:error, %Ash.Error.Query.NotFound{}} ->
        exists? =
          resource
          |> Ash.Query.do_filter(pk_filter(resource, pk))
          |> Ash.exists?(Keyword.take(opts, [:tenant, :context]) ++ [authorize?: false])

        if exists?,
          do:
            {:error, Ash.Error.to_error_class(SubjectUnreachable.exception(resource: resource))},
          else:
            {:error,
             Ash.Error.to_error_class(Ash.Error.Query.NotFound.exception(resource: resource))}

      other ->
        other
    end
  end

  # What is recorded as the result: enough to find what the target touched, never the
  # whole record, which may carry content the invocation was not asked to keep.
  defp summarize(%{__struct__: resource} = record) do
    if Ash.Resource.Info.resource?(resource),
      do: %{"resource" => inspect(resource), "id" => primary_key_string(resource, record)},
      else: %{"value" => inspect(record)}
  end

  defp summarize(records) when is_list(records),
    do: %{"values" => Enum.map(records, &summarize/1)}

  defp summarize(value) do
    %{"value" => AshAgent.Digest.canonical(value)}
  rescue
    ArgumentError -> %{"value" => inspect(value)}
  end

  # --- resolving ---------------------------------------------------------------------

  defp split(name) do
    case String.split(name, ".") do
      [_one] -> :error
      parts -> [parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)]
    end
  end

  # Law: never create an atom from a caller's string. A target names code that is
  # already loaded, so its module and action atoms already exist.
  defp resource(module_name) do
    module = String.to_existing_atom("Elixir." <> module_name)

    if Ash.Resource.Info.resource?(module),
      do: {:ok, module},
      else: {:error, "#{module_name} is not an Ash resource"}
  rescue
    ArgumentError -> {:error, "#{module_name} is not an Ash resource"}
  end

  defp action(resource, action_name) do
    case Ash.Resource.Info.action(resource, String.to_existing_atom(action_name)) do
      nil -> {:error, "#{inspect(resource)} has no action #{action_name}"}
      action -> {:ok, action}
    end
  rescue
    ArgumentError -> {:error, "#{inspect(resource)} has no action #{action_name}"}
  end

  defp effect(resource, action) do
    case AshAgent.Effects.Info.effect(resource, action.name) do
      nil ->
        {:error,
         "#{name(resource, action.name)} declares no effects, so it cannot be invoked; " <>
           "declare it in the resource's `effects` section"}

      effect ->
        {:ok, effect}
    end
  end

  # --- checking arguments ------------------------------------------------------------

  defp primary_key_names(resource, %{type: type}) when type in [:update, :destroy],
    do: resource |> Ash.Resource.Info.primary_key() |> Enum.map(&Atom.to_string/1)

  defp primary_key_names(_resource, _action), do: []

  defp cast_inputs(resource, action, inputs) do
    fields = input_fields(resource, action)

    {cast, errors} =
      Enum.reduce(inputs, {%{}, []}, fn {key, value}, {cast, errors} ->
        case Map.fetch(fields, key) do
          {:ok, field} -> cast_one(field, value, cast, errors)
          :error -> {cast, ["#{key} is not an input of #{action.name}" | errors]}
        end
      end)

    missing =
      for {key, field} <- fields, field.required?, not Map.has_key?(inputs, key) do
        "#{key} is required"
      end

    case Enum.reverse(errors) ++ Enum.sort(missing) do
      [] -> {:ok, cast}
      messages -> {:error, messages}
    end
  end

  defp cast_one(field, value, cast, errors) do
    with {:ok, value} <- Ash.Type.cast_input(field.type, value, field.constraints),
         {:ok, value} <- Ash.Type.apply_constraints(field.type, value, field.constraints) do
      {Map.put(cast, field.name, value), errors}
    else
      _ -> {cast, ["#{field.name} is not a valid #{inspect(field.type)}" | errors]}
    end
  end

  # The action's arguments, plus the attributes it accepts. On a create, an accepted
  # attribute that cannot be nil and has no default is required; on other actions an
  # accepted attribute is optional.
  defp input_fields(resource, action) do
    arguments =
      for argument <- action.arguments, argument.public? do
        {Atom.to_string(argument.name),
         %{
           name: Atom.to_string(argument.name),
           type: argument.type,
           constraints: argument.constraints,
           required?: not argument.allow_nil? and is_nil(argument.default)
         }}
      end

    accepted =
      for name <- Map.get(action, :accept, []),
          attribute = Ash.Resource.Info.attribute(resource, name) do
        {Atom.to_string(name),
         %{
           name: Atom.to_string(name),
           type: attribute.type,
           constraints: attribute.constraints,
           required?:
             action.type == :create and not attribute.allow_nil? and is_nil(attribute.default) and
               not attribute.generated? and name not in Map.get(action, :allow_nil_input, [])
         }}
      end

    Map.new(accepted ++ arguments)
  end

  defp subject(resource, %{type: type}, pk, opts) when type in [:update, :destroy] do
    names = Ash.Resource.Info.primary_key(resource)

    if Enum.all?(names, &Map.has_key?(pk, Atom.to_string(&1))) do
      case get(resource, pk, opts) do
        {:ok, record} -> {:ok, record}
        {:error, _not_found_or_forbidden} -> {:error, ["the record to act on was not found"]}
      end
    else
      {:error, ["#{Enum.join(names, ", ")} must name the record to act on"]}
    end
  end

  defp subject(_resource, _action, _pk, _opts), do: {:ok, nil}

  defp pk_filter(resource, pk) do
    for name <- Ash.Resource.Info.primary_key(resource) do
      {name, Map.get(pk, Atom.to_string(name))}
    end
  end

  defp primary_key_string(resource, record) do
    resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.map_join(",", &to_string(Map.get(record, &1)))
  end
end
