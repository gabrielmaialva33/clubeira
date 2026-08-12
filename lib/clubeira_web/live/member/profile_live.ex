defmodule ClubeiraWeb.Member.ProfileLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.People
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.MemberComponents

  @profile_fields ~w(display_name birth_date cpf phone)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("My profile")) |> load_profile()}
  end

  @impl true
  def handle_event("validate_profile", %{"self_profile" => params}, socket)
      when is_map(params) do
    changeset = params |> Map.take(@profile_fields) |> People.change_self_profile()

    {:noreply,
     assign(socket, :profile_form, to_form(%{changeset | action: :validate}, as: :self_profile))}
  end

  def handle_event("validate_profile", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The profile form was invalid."))}
  end

  def handle_event("save_profile", %{"self_profile" => params}, socket) when is_map(params) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} ->
        save_profile(assign(socket, :current_account_scope, account_scope), params)

      :error ->
        expired_session(socket)
    end
  end

  def handle_event("save_profile", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The profile form was invalid."))}
  end

  defp save_profile(socket, params) do
    attributes = params |> Map.take(@profile_fields) |> omit_blank_sensitive()

    case People.put_self_profile(actor_scope(socket), attributes) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign_profile(profile)
         |> put_flash(:info, gettext("Your profile was updated."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:profile_form, to_form(changeset, as: :self_profile))
         |> put_flash(:error, gettext("Review your profile before saving."))}

      {:error, reason} when reason in [:identifier_conflict, :contact_conflict] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This CPF or phone is already linked to another profile.")
         )}

      {:error, reason} ->
        Logger.error("could not save member profile", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, gettext("Your profile could not be updated."))}
    end
  end

  defp load_profile(socket) do
    case People.get_self_profile(actor_scope(socket)) do
      {:ok, profile} ->
        assign_profile(socket, profile)

      {:error, :profile_not_found} ->
        socket
        |> assign(:profile, nil)
        |> assign(:profile_form, new_form(%{}))

      {:error, reason} ->
        Logger.error("could not load member profile", reason: inspect(reason))

        socket
        |> assign(:profile, nil)
        |> assign(:profile_form, new_form(%{}))
        |> put_flash(:error, gettext("Your profile is temporarily unavailable."))
    end
  end

  defp assign_profile(socket, profile) do
    socket
    |> assign(:profile, profile)
    |> assign(
      :profile_form,
      new_form(%{
        "display_name" => profile.display_name,
        "birth_date" => profile.birth_date
      })
    )
  end

  defp new_form(attributes) do
    attributes |> People.change_self_profile() |> to_form(as: :self_profile)
  end

  defp omit_blank_sensitive(attributes) do
    Enum.reduce(~w(cpf phone), attributes, fn field, acc ->
      case Map.get(acc, field) do
        value when value in [nil, ""] -> Map.delete(acc, field)
        _value -> acc
      end
    end)
  end

  defp actor_scope(socket) do
    account_scope = socket.assigns.current_account_scope
    ActorScope.new!(account_scope.user.id, account_scope.request_id)
  end

  defp expired_session(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your session has expired. Sign in again."))
     |> redirect(to: ~p"/app/login")}
  end

  defp credential_present?(nil, _kind), do: false
  defp credential_present?(profile, kind), do: Enum.any?(profile.identifiers, &(&1.kind == kind))
  defp contact_present?(nil, _kind), do: false
  defp contact_present?(profile, kind), do: Enum.any?(profile.contact_points, &(&1.kind == kind))
end
