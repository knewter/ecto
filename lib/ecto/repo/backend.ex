defmodule Ecto.Repo.Backend do
  # The backend invoked by user defined repos.
  @moduledoc false

  alias Ecto.Queryable
  alias Ecto.Query.Query
  alias Ecto.Query.Util
  alias Ecto.Query.FromBuilder
  alias Ecto.Query.BuilderUtil
  require Ecto.Query, as: Q

  def start_link(repo, adapter) do
    Enum.each(repo.query_apis, &Code.ensure_loaded(&1))
    adapter.start_link(repo, parse_url(repo.url))
  end

  def stop(repo, adapter) do
    adapter.stop(repo)
  end

  def get(repo, adapter, queryable, id) when is_integer(id) do
    reason      = "getting entity"
    query       = Queryable.to_query(queryable)
    entity      = query.from |> Util.entity
    primary_key = entity.__entity__(:primary_key)

    Util.validate_get(query, repo.query_apis)
    check_primary_key(entity, reason)

    # TODO: Maybe it would indeed be better to emit a direct AST
    # instead of building it up so we don't need to pass through
    # normalization and what not.
    query = Q.from(x in query,
                   where: field(x, ^primary_key) == ^id,
                   limit: 1) |> Util.normalize

    case adapter.all(repo, query) |> check_result(adapter, reason) do
      [entity] -> entity
      [] -> nil
      _ -> raise Ecto.NotSingleResult, entity: entity
    end
  end

  def all(repo, adapter, queryable) do
    query = Queryable.to_query(queryable) |> Util.normalize
    Util.validate(query, repo.query_apis)
    reason = "fetching entities"
    result = adapter.all(repo, query) |> check_result(adapter, reason)

    if query.preloads == [] do
      result
    else
      preload(repo, query, result)
    end
  end

  def create(repo, adapter, entity) do
    reason = "creating an entity"
    validate_entity(entity, reason)
    primary_key = adapter.create(repo, entity) |> check_result(adapter, reason)

    if primary_key do
      entity.primary_key(primary_key)
    else
      entity
    end
  end

  def update(repo, adapter, entity) do
    reason = "updating an entity"
    check_primary_key(entity, reason)
    validate_entity(entity, reason)

    adapter.update(repo, entity)
      |> check_result(adapter, reason)
      |> check_single_result(entity)
  end

  def update_all(repo, adapter, queryable, values) do
    { binds, expr } = FromBuilder.escape(queryable)

    values = Enum.map(values, fn({ field, expr }) ->
      expr = BuilderUtil.escape(expr, binds)
      { field, expr }
    end)

    quote do
      Ecto.Repo.Backend.runtime_update_all(unquote(repo),
        unquote(adapter), unquote(expr), unquote(values))
    end
  end

  def runtime_update_all(repo, adapter, queryable, values) do
    query = Queryable.to_query(queryable) |> Util.normalize(skip_select: true)
    Util.validate_update(query, repo.query_apis, values)

    reason = "updating entities"
    adapter.update_all(repo, query, values) |> check_result(adapter, reason)
  end

  def delete(repo, adapter, entity) do
    reason = "deleting an entity"
    check_primary_key(entity, reason)
    validate_entity(entity, reason)

    adapter.delete(repo, entity)
      |> check_result(adapter, reason)
      |> check_single_result(entity)
  end

  def delete_all(repo, adapter, queryable) do
    query = Queryable.to_query(queryable) |> Util.normalize(skip_select: true)
    Util.validate_delete(query, repo.query_apis)

    reason = "deleting entities"
    adapter.delete_all(repo, query) |> check_result(adapter, reason)
  end

  ## Helpers

  defp parse_url(url) do
    info = URI.parse(url)

    unless info.scheme == "ecto" do
      raise Ecto.InvalidURL, url: url, reason: "not an ecto url"
    end

    unless is_binary(info.userinfo) and size(info.userinfo) > 0  do
      raise Ecto.InvalidURL, url: url, reason: "url has to contain a username"
    end

    unless info.path =~ %r"^/([^/])+$" do
      raise Ecto.InvalidURL, url: url, reason: "path should be a database name"
    end

    destructure [username, password], String.split(info.userinfo, ":")
    database = String.slice(info.path, 1, size(info.path))
    query = URI.decode_query(info.query || "", []) |> atomize_keys

    opts = [ username: username,
             hostname: info.host,
             database: database ]

    if password,  do: opts = [password: password] ++ opts
    if info.port, do: opts = [port: info.port] ++ opts

    opts ++ query
  end

  defp atomize_keys(dict) do
    Enum.map dict, fn({ k, v }) -> { binary_to_atom(k), v } end
  end

  defp check_result(result, adapter, reason) do
    case result do
      :ok -> :ok
      { :ok, res } -> res
      { :error, err } ->
        raise Ecto.AdapterError, adapter: adapter, reason: reason, internal: err
    end
  end

  defp check_single_result(result, entity) do
    unless result == 1 do
      module = elem(entity, 0)
      pk_field = module.__entity__(:primary_key)
      pk_value = entity.primary_key
      raise Ecto.NotSingleResult, entity: module, primary_key: pk_field, id: pk_value
    end
    :ok
  end

  defp check_primary_key(entity, reason) when is_atom(entity) do
    unless entity.__entity__(:primary_key) do
      raise Ecto.NoPrimaryKey, entity: entity, reason: reason
    end
  end

  defp check_primary_key(entity, reason) when is_record(entity) do
    module = elem(entity, 0)
    unless module.__entity__(:primary_key) && entity.primary_key do
      raise Ecto.NoPrimaryKey, entity: entity, reason: reason
    end
  end

  defp validate_entity(entity, reason) do
    module = elem(entity, 0)
    primary_key = module.__entity__(:primary_key)
    zipped = module.__entity__(:entity_kw, entity)

    Enum.each(zipped, fn({ field, value }) ->
      type = module.__entity__(:field_type, field)

      value_type = case Util.value_to_type(value) do
        { :ok, vtype } -> vtype
        { :error, reason } -> raise ArgumentError, message: reason
      end

      valid = field == primary_key or
              value_type == nil or
              Util.type_eq?(value_type, type)

      # TODO: Check if entity field allows nil
      unless valid do
        raise Ecto.InvalidEntity, entity: entity, field: field,
          type: value_type, expected_type: type, reason: reason
      end
    end)
  end

  defp preload(repo, Query[] = query, results) do
    pos = Util.locate_var(query.select.expr, { :&, [], [0] })
    preloads = Enum.map(query.preloads, &(&1.expr)) |> Enum.concat

    Enum.reduce(preloads, results, fn field, acc ->
      Ecto.Preloader.run(repo, acc, field, pos)
    end)
  end
end
