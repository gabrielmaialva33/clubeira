defmodule ClubeiraWeb.Platform.BillingPlansLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.PlatformBilling
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.PlatformAuth
  alias ClubeiraWeb.PlatformComponents

  @page_limit "20"
  @query_fields ~w(after limit)
  @identity_fields ~w(code version)
  @publish_fields ~w(
    amount billing_interval_count billing_interval_unit currency description features name
    valid_from valid_until version_name
  )
  @price_fields ~w(
    amount billing_interval_count billing_interval_unit currency valid_from valid_until
  )
  @feature_fields ~w(boolean_value integer_value key name value_kind)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:plans, dom_id: &"managed-platform-plan-#{&1.id}")
     |> assign(:page_title, gettext("Platform plans"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if :manage_platform_billing in socket.assigns.platform_access.capabilities do
      load_workspace(socket, params)
    else
      redirect_unauthorized(socket)
    end
  end

  @impl true
  def handle_event("validate_plan", %{"plan" => params}, socket) when is_map(params) do
    params = normalize_publish_params(params)

    form =
      params
      |> PlatformBilling.change_plan_publish_request()
      |> Map.put(:action, :validate)
      |> to_form(as: :plan)

    {:noreply,
     socket
     |> assign(:publish_params, params)
     |> assign(:publish_form, form)
     |> assign(:identity_form, identity_form(params))}
  end

  def handle_event("validate_plan", _params, socket), do: {:noreply, socket}

  def handle_event("add_plan_feature", _params, socket) do
    params =
      Map.update(
        socket.assigns.publish_params,
        "features",
        [blank_feature()],
        &(&1 ++ [blank_feature()])
      )

    {:noreply, assign_publish_form(socket, params, :validate)}
  end

  def handle_event("remove_plan_feature", %{"index" => index}, socket)
      when is_binary(index) do
    case Integer.parse(index) do
      {index, ""} when index >= 0 ->
        features =
          socket.assigns.publish_params
          |> Map.get("features", [])
          |> List.delete_at(index)
          |> ensure_feature_row()

        params = Map.put(socket.assigns.publish_params, "features", features)
        {:noreply, assign_publish_form(socket, params, :validate)}

      _invalid ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_plan_feature", _params, socket), do: {:noreply, socket}

  def handle_event("publish_plan", %{"plan" => params}, socket) when is_map(params) do
    case refresh_platform_access(socket) do
      {:ok, socket} -> publish_plan(socket, params)
      {:error, :expired_session} -> redirect_expired_session(socket)
      {:error, :forbidden} -> redirect_unauthorized(socket)
    end
  end

  def handle_event("publish_plan", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The platform plan publication request was invalid."))}
  end

  defp load_workspace(socket, params) do
    query_params = params |> Map.take(@query_fields) |> Map.put_new("limit", @page_limit)

    case PlatformBilling.list_managed_plans(actor_scope(socket), query_params) do
      {:ok, result} ->
        known_features = known_features(result.plans)

        socket =
          if Map.has_key?(socket.assigns, :publish_form) do
            socket
          else
            initialize_publish_form(socket)
          end

        {:noreply,
         socket
         |> assign(:query_params, query_params)
         |> assign(:page, result.page)
         |> assign(:known_features, known_features)
         |> assign(:next_page_path, next_page_path(query_params, result.page))
         |> stream(:plans, result.plans, reset: true)}

      {:error, :platform_billing_admin_required} ->
        redirect_unauthorized(socket)

      {:error, :invalid_pagination} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The plan page was invalid and has been reset."))
         |> redirect(to: billing_plans_path())}

      {:error, reason} ->
        Logger.error("could not load managed platform plans", reason: inspect(reason))

        {:noreply,
         socket
         |> put_flash(:error, gettext("The platform plan inventory is temporarily unavailable."))
         |> redirect(to: ~p"/platform")}
    end
  end

  defp publish_plan(socket, params) do
    params = normalize_publish_params(params)
    identity = Map.take(params, @identity_fields)

    case plan_identity(identity) do
      {:ok, code, version} ->
        publish_plan_version(socket, params, identity, code, version)

      {:error, :invalid_platform_plan_identity} ->
        invalid_identity(socket, params)
    end
  end

  defp publish_plan_version(socket, params, identity, code, version) do
    attributes = publication_attributes(params)

    case PlatformBilling.publish_plan(actor_scope(socket), code, version, attributes) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> initialize_publish_form()
         |> put_flash(:info, gettext("The platform plan version was published."))
         |> push_patch(to: billing_plans_path())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:publish_params, params)
         |> assign(:publish_form, to_form(changeset, as: :plan))
         |> assign(:identity_form, identity_form(identity))
         |> put_flash(:error, gettext("Review the plan data before publishing."))}

      {:error, :invalid_platform_plan_identity} ->
        invalid_identity(socket, params)

      {:error, reason}
      when reason in [
             :platform_feature_conflict,
             :platform_plan_retired,
             :platform_plan_version_conflict,
             :platform_plan_version_gap
           ] ->
        reload_inventory_after_conflict(socket, params)

      {:error, :platform_billing_admin_required} ->
        redirect_unauthorized(socket)

      {:error, reason} ->
        Logger.error("could not publish platform plan", reason: inspect(reason))

        {:noreply,
         put_flash(socket, :error, gettext("The platform plan could not be published."))}
    end
  end

  defp reload_inventory_after_conflict(socket, params) do
    case PlatformBilling.list_managed_plans(actor_scope(socket), socket.assigns.query_params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:publish_params, params)
         |> assign(:publish_form, publish_form(params, :validate))
         |> assign(:identity_form, identity_form(params))
         |> assign(:page, result.page)
         |> assign(:known_features, known_features(result.plans))
         |> assign(:next_page_path, next_page_path(socket.assigns.query_params, result.page))
         |> stream(:plans, result.plans, reset: true)
         |> put_flash(
           :error,
           gettext("The plan changed before publication. Review the current inventory and retry.")
         )}

      {:error, :platform_billing_admin_required} ->
        redirect_unauthorized(socket)

      {:error, reason} ->
        Logger.error("could not reload managed platform plans after conflict",
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated plan inventory could not be reloaded."))
         |> redirect(to: billing_plans_path())}
    end
  end

  defp initialize_publish_form(socket) do
    params = default_publish_params()

    socket
    |> assign(:publish_params, params)
    |> assign(:publish_form, publish_form(params))
    |> assign(:identity_form, identity_form(params))
  end

  defp assign_publish_form(socket, params, action) do
    socket
    |> assign(:publish_params, params)
    |> assign(:publish_form, publish_form(params, action))
    |> assign(:identity_form, identity_form(params))
  end

  defp publish_form(params, action \\ nil) do
    changeset = PlatformBilling.change_plan_publish_request(params)
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset
    to_form(changeset, as: :plan)
  end

  defp identity_form(params) do
    params
    |> Map.take(@identity_fields)
    |> Map.put_new("code", "")
    |> Map.put_new("version", "1")
    |> to_form(as: :plan)
  end

  defp refresh_platform_access(socket) do
    with {:ok, account_scope} <- Accounts.refresh_scope(socket.assigns.current_account_scope),
         {:ok, access} <- PlatformAuth.authorize(account_scope),
         true <- :manage_platform_billing in access.capabilities do
      {:ok,
       socket
       |> assign(:current_account_scope, account_scope)
       |> assign(:platform_access, access)}
    else
      :error -> {:error, :expired_session}
      {:error, _reason} -> {:error, :forbidden}
      false -> {:error, :forbidden}
    end
  end

  defp actor_scope(socket) do
    account_scope = socket.assigns.current_account_scope
    ActorScope.new!(account_scope.user.id, account_scope.request_id)
  end

  defp publication_attributes(params) do
    params
    |> Map.take(~w(description features name version_name))
    |> Map.put("price", Map.take(params, @price_fields))
  end

  defp normalize_publish_params(params) do
    params
    |> Map.take(@identity_fields ++ @publish_fields)
    |> Map.put("features", normalize_features(params["features"]))
  end

  defp normalize_features(features) when is_list(features) do
    Enum.map(features, &normalize_feature/1)
  end

  defp normalize_features(features) when is_map(features) do
    features
    |> Enum.sort_by(fn {index, _feature} -> feature_index(index) end)
    |> Enum.map(fn {_index, feature} -> normalize_feature(feature) end)
  end

  defp normalize_features(_features), do: []

  defp normalize_feature(feature) when is_map(feature) do
    feature = Map.take(feature, @feature_fields)

    case feature["value_kind"] do
      "boolean" -> Map.put(feature, "integer_value", nil)
      "integer" -> Map.put(feature, "boolean_value", nil)
      _unknown -> feature
    end
  end

  defp normalize_feature(_feature), do: %{}

  defp plan_identity(%{"code" => code, "version" => version})
       when is_binary(code) and is_binary(version) do
    case Integer.parse(version) do
      {parsed_version, ""} when parsed_version > 0 ->
        {:ok, String.trim(code), parsed_version}

      _invalid ->
        {:error, :invalid_platform_plan_identity}
    end
  end

  defp plan_identity(_identity), do: {:error, :invalid_platform_plan_identity}

  defp feature_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {parsed, ""} -> {0, parsed}
      _invalid -> {1, index}
    end
  end

  defp feature_index(index), do: {1, inspect(index)}

  defp invalid_identity(socket, params) do
    {:noreply,
     socket
     |> assign_publish_form(params, :validate)
     |> put_flash(:error, gettext("Use a valid plan code and a positive version number."))}
  end

  defp ensure_feature_row([]), do: [blank_feature()]
  defp ensure_feature_row(features), do: features

  defp default_publish_params do
    now = DateTime.utc_now(:second)

    %{
      "code" => "",
      "version" => "1",
      "name" => "",
      "version_name" => "",
      "description" => "",
      "currency" => "BRL",
      "amount" => "",
      "billing_interval_unit" => "month",
      "billing_interval_count" => "1",
      "valid_from" => DateTime.to_iso8601(now),
      "valid_until" => now |> DateTime.add(31_536_000) |> DateTime.to_iso8601(),
      "features" => [blank_feature()]
    }
  end

  defp blank_feature do
    %{
      "key" => "",
      "name" => "",
      "value_kind" => "integer",
      "boolean_value" => nil,
      "integer_value" => "0"
    }
  end

  defp known_features(plans) do
    plans
    |> Enum.flat_map(& &1.versions)
    |> Enum.flat_map(& &1.features)
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.uniq_by(& &1.key)
    |> Enum.sort_by(& &1.key)
  end

  defp next_page_path(_params, %{has_more: false}), do: nil

  defp next_page_path(params, page) do
    query =
      params
      |> Map.take(["limit"])
      |> Map.put("after", page.next_cursor)
      |> URI.encode_query()

    billing_plans_path() <> "?" <> query
  end

  defp billing_plans_path, do: "/platform/billing/plans"

  defp redirect_unauthorized(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to manage platform billing."))
     |> redirect(to: ~p"/platform")}
  end

  defp redirect_expired_session(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your session has expired. Sign in again to continue."))
     |> redirect(to: ~p"/platform/login")}
  end

  defp status_label("active"), do: gettext("Active")
  defp status_label("draft"), do: gettext("Draft")
  defp status_label("published"), do: gettext("Published")
  defp status_label("retired"), do: gettext("Retired")
  defp status_label(status), do: status

  defp feature_value(%{value_kind: "boolean", boolean_value: true}), do: gettext("Enabled")
  defp feature_value(%{value_kind: "boolean", boolean_value: false}), do: gettext("Disabled")

  defp feature_value(%{value_kind: "integer", integer_value: value}) do
    ngettext("%{count} unit", "%{count} units", value, count: value)
  end

  defp feature_value(_feature), do: gettext("Not configured")

  defp price_period(%{billing_interval_count: count, billing_interval_unit: "month"}) do
    ngettext("every month", "every %{count} months", count, count: count)
  end

  defp price_period(%{billing_interval_count: count, billing_interval_unit: "year"}) do
    ngettext("every year", "every %{count} years", count, count: count)
  end

  defp price_period(price), do: "#{price.billing_interval_count} #{price.billing_interval_unit}"

  defp date_label(%DateTime{} = value), do: Calendar.strftime(value, "%d/%m/%Y")
  defp date_label(_value), do: gettext("Open ended")
end
