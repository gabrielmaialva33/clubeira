defmodule Clubeira.Bootstrap do
  @moduledoc """
  Idempotent production bootstrap for the first operational polo.

  This is a privileged, explicit one-off boundary. It creates only structural
  data and never manufactures a user or credential. When `admin_email` is in
  the manifest, the command can be rerun after normal registration and email
  verification to grant the initial polo administrator role.
  """

  import Ecto.Query

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.User
  alias Clubeira.Audit
  alias Clubeira.Audit.SystemEvent
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PoloMerchantAccount
  alias Clubeira.Bootstrap.Manifest
  alias Clubeira.Directory.City
  alias Clubeira.Legal.Document
  alias Clubeira.Legal.DocumentVersion
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloMembership
  alias Clubeira.Polos.PoloMembershipRole
  alias Clubeira.Polos.PoloRole
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @bootstrap_lock "clubeira.production_bootstrap.v1"
  @operation_metadata_fields %{
    "fingerprint" => :fingerprint,
    "legal_content_sha256" => :legal_content_sha256
  }

  @type admin_status ::
          :not_configured
          | :pending_registration
          | :pending_verification
          | :ineligible
          | :granted
          | :already_granted

  @type result :: %{
          polo_id: Ecto.UUID.t(),
          legal_document_version_id: Ecto.UUID.t(),
          merchant_account_id: Ecto.UUID.t(),
          admin_status: admin_status()
        }

  @type error ::
          :migrator_role_required
          | {:bootstrap_drift, atom(), [atom()]}
          | term()

  @spec run(Manifest.t()) :: {:ok, result()} | {:error, error()}
  def run(%Manifest{} = manifest) do
    with :ok <- ensure_migrator_role() do
      Repo.transact(
        fn repo -> apply_manifest(repo, manifest) end,
        timeout: :infinity
      )
    end
  end

  defp ensure_migrator_role do
    %{rows: [[owns_schema?]]} =
      Repo.query!("""
      SELECT current_user = pg_get_userbyid(relowner)
      FROM pg_class
      WHERE oid = 'public.polos'::regclass
      """)

    if owns_schema?, do: :ok, else: {:error, :migrator_role_required}
  end

  defp apply_manifest(repo, manifest) do
    repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [@bootstrap_lock])

    now = database_now(repo)
    content_sha256 = manifest.legal.content_file |> File.read!() |> sha256()
    fingerprint = Manifest.fingerprint(manifest)

    verify_operation_identity!(repo, manifest, fingerprint, content_sha256)

    {city, _city_created?} = ensure_city!(repo, manifest, now)
    {document_version, _legal_created?} = ensure_legal!(repo, manifest, now, content_sha256)
    {provider, account, _billing_created?} = ensure_billing!(repo, manifest, now)

    scope = Scope.new!(manifest.polo_id, request_id: manifest.operation_id)

    {:ok, scoped} =
      Repo.transact_in_polo(scope, fn scoped_repo ->
        {polo, _polo_created?} = ensure_polo!(scoped_repo, manifest, city, now)
        {_route, _route_created?} = ensure_route!(scoped_repo, manifest, polo, now)
        {role, _role_created?} = ensure_admin_role!(scoped_repo, polo, now)

        {_link, _link_created?} =
          ensure_merchant_link!(scoped_repo, manifest, polo, provider, account, now)

        admin_status = ensure_initial_admin!(scoped_repo, scope, manifest, role, now)

        {:ok, %{polo: polo, admin_status: admin_status}}
      end)

    ensure_system_audit!(
      repo,
      manifest,
      scoped.polo,
      fingerprint,
      content_sha256,
      now
    )

    {:ok,
     %{
       polo_id: scoped.polo.id,
       legal_document_version_id: document_version.id,
       merchant_account_id: account.id,
       admin_status: scoped.admin_status
     }}
  end

  defp ensure_city!(repo, manifest, now) do
    expected =
      manifest.city
      |> Map.put(:status, "active")

    query =
      from city in City,
        where:
          city.country_code == ^expected.country_code and
            city.subdivision_code == ^expected.subdivision_code and
            city.external_code == ^expected.external_code

    ensure_record!(
      repo,
      :city,
      query,
      struct(City, Map.merge(expected, timestamps(now))),
      expected
    )
  end

  defp ensure_legal!(repo, manifest, now, content_sha256) do
    document_expected = %{
      code: manifest.legal.code,
      document_kind: "terms_of_service",
      audience: "consumer",
      status: "active"
    }

    document_query = from document in Document, where: document.code == ^manifest.legal.code

    {document, document_created?} =
      ensure_record!(
        repo,
        :legal_document,
        document_query,
        struct(Document, Map.merge(document_expected, timestamps(now))),
        document_expected
      )

    range = open_range(manifest.legal.effective_from)

    version_expected = %{
      legal_document_id: document.id,
      version: manifest.legal.version,
      locale: manifest.legal.locale,
      content_uri: manifest.legal.content_uri,
      content_sha256: content_sha256,
      effective_during: range,
      published_at: manifest.legal.effective_from
    }

    version_query =
      from version in DocumentVersion,
        where:
          version.legal_document_id == ^document.id and
            version.locale == ^manifest.legal.locale and
            version.version == ^manifest.legal.version

    {version, version_created?} =
      ensure_record!(
        repo,
        :legal_document_version,
        version_query,
        struct(DocumentVersion, Map.put(version_expected, :inserted_at, now)),
        version_expected
      )

    {version, document_created? or version_created?}
  end

  defp ensure_billing!(repo, manifest, now) do
    provider_expected = %{
      code: manifest.billing.provider_code,
      name: manifest.billing.provider_name,
      status: "active"
    }

    provider_query =
      from provider in PaymentProvider, where: provider.code == ^manifest.billing.provider_code

    {provider, provider_created?} =
      ensure_record!(
        repo,
        :payment_provider,
        provider_query,
        struct(PaymentProvider, Map.merge(provider_expected, timestamps(now))),
        provider_expected
      )

    account_expected = %{
      payment_provider_id: provider.id,
      kind: "consumer",
      name: manifest.billing.merchant_account_name,
      provider_account_reference: manifest.billing.merchant_account_reference,
      status: "active"
    }

    account_query =
      from account in MerchantAccount,
        where:
          account.payment_provider_id == ^provider.id and
            account.provider_account_reference ==
              ^manifest.billing.merchant_account_reference

    {account, account_created?} =
      ensure_record!(
        repo,
        :merchant_account,
        account_query,
        struct(MerchantAccount, Map.merge(account_expected, timestamps(now))),
        account_expected
      )

    {provider, account, provider_created? or account_created?}
  end

  defp ensure_polo!(repo, manifest, city, now) do
    expected = %{
      id: manifest.polo_id,
      city_id: city.id,
      name: manifest.polo.name,
      timezone: manifest.polo.timezone,
      status: "active"
    }

    query = from polo in Polo, where: polo.id == ^manifest.polo_id

    ensure_record!(
      repo,
      :polo,
      query,
      struct(Polo, Map.merge(expected, timestamps(now))),
      expected
    )
  end

  defp ensure_route!(repo, manifest, polo, now) do
    expected = %{polo_id: polo.id, slug: manifest.polo.slug}
    query = from route in PoloRoute, where: route.polo_id == ^polo.id

    case repo.one(query) do
      nil ->
        case repo.one(from route in PoloRoute, where: route.slug == ^manifest.polo.slug) do
          nil ->
            ensure_record!(
              repo,
              :polo_route,
              query,
              struct(PoloRoute, Map.merge(expected, timestamps(now))),
              expected
            )

          _other ->
            rollback_drift!(repo, :polo_route, [:polo_id])
        end

      route ->
        {assert_expected!(repo, :polo_route, route, expected), false}
    end
  end

  defp ensure_admin_role!(repo, polo, now) do
    expected = %{polo_id: polo.id, key: "admin", name: "Administrador", status: "active"}

    query =
      from role in PoloRole,
        where: role.polo_id == ^polo.id and role.key == "admin"

    ensure_record!(
      repo,
      :polo_role,
      query,
      struct(PoloRole, Map.merge(expected, timestamps(now))),
      expected
    )
  end

  defp ensure_merchant_link!(repo, manifest, polo, provider, account, now) do
    range = open_range(manifest.billing.valid_from)

    expected = %{
      polo_id: polo.id,
      payment_provider_id: provider.id,
      merchant_account_id: account.id,
      role: "primary",
      valid_during: range
    }

    query =
      from link in PoloMerchantAccount,
        where:
          link.polo_id == ^polo.id and
            link.merchant_account_id == ^account.id

    case repo.one(query) do
      nil ->
        conflicting_primary =
          repo.one(
            from link in PoloMerchantAccount,
              where:
                link.polo_id == ^polo.id and
                  link.payment_provider_id == ^provider.id and
                  link.role == "primary" and
                  fragment("? && ?", link.valid_during, type(^range, Clubeira.Types.TstzRange))
          )

        if conflicting_primary do
          rollback_drift!(repo, :polo_merchant_account, [:merchant_account_id])
        else
          ensure_record!(
            repo,
            :polo_merchant_account,
            query,
            struct(PoloMerchantAccount, Map.put(expected, :inserted_at, now)),
            expected
          )
        end

      link ->
        {assert_expected!(repo, :polo_merchant_account, link, expected), false}
    end
  end

  defp ensure_initial_admin!(_repo, _scope, %Manifest{admin_email: nil}, _role, _now),
    do: :not_configured

  defp ensure_initial_admin!(repo, scope, manifest, role, now) do
    case repo.one(from user in User, where: user.email == ^manifest.admin_email) do
      nil ->
        :pending_registration

      %User{status: status} when status != "active" ->
        :ineligible

      %User{email_verified_at: nil} ->
        :pending_verification

      %User{} = user ->
        grant_initial_admin!(repo, scope, user, role, now)
    end
  end

  defp grant_initial_admin!(repo, scope, user, role, now) do
    {membership, _membership_created?} = ensure_active_membership!(repo, scope, user, now)

    if ensure_admin_assignment!(repo, scope, membership, role, now) do
      Audit.record_tenant!(repo, scope, %{
        actor_kind: "system",
        action: "bootstrap.admin_granted",
        resource_type: "polo_membership",
        resource_id: membership.id,
        metadata: %{"role" => "admin"},
        occurred_at: now
      })

      :granted
    else
      :already_granted
    end
  end

  defp ensure_active_membership!(repo, scope, user, now) do
    query =
      from membership in PoloMembership,
        where:
          membership.polo_id == ^scope.polo_id and
            membership.user_id == ^user.id and
            membership.status == "active" and
            fragment(
              "? @> (? AT TIME ZONE 'UTC')",
              membership.valid_during,
              type(^now, :utc_datetime_usec)
            )

    case repo.one(query) do
      nil ->
        membership =
          repo.insert!(%PoloMembership{
            polo_id: scope.polo_id,
            user_id: user.id,
            valid_during: open_range(now),
            status: "active",
            inserted_at: now,
            updated_at: now
          })

        {membership, true}

      membership ->
        {membership, false}
    end
  end

  defp ensure_admin_assignment!(repo, scope, membership, role, now) do
    query =
      from assignment in PoloMembershipRole,
        where:
          assignment.polo_id == ^scope.polo_id and
            assignment.polo_membership_id == ^membership.id and
            assignment.polo_role_id == ^role.id

    case repo.one(query) do
      nil ->
        repo.insert!(%PoloMembershipRole{
          polo_id: scope.polo_id,
          polo_membership_id: membership.id,
          polo_role_id: role.id,
          inserted_at: now
        })

        true

      _assignment ->
        false
    end
  end

  defp verify_operation_identity!(repo, manifest, fingerprint, content_sha256) do
    query =
      from event in SystemEvent,
        where:
          event.request_id == ^manifest.operation_id and
            event.action == "bootstrap.foundation_applied",
        order_by: [asc: event.inserted_at],
        limit: 1

    case repo.one(query) do
      nil ->
        :ok

      event ->
        expected = %{
          "fingerprint" => fingerprint,
          "legal_content_sha256" => Base.encode16(content_sha256, case: :lower)
        }

        differing =
          expected
          |> Enum.reject(fn {key, value} -> event.metadata[key] == value end)
          |> Enum.map(fn {key, _value} -> Map.fetch!(@operation_metadata_fields, key) end)

        if differing == [], do: :ok, else: rollback_drift!(repo, :bootstrap_operation, differing)
    end
  end

  defp ensure_system_audit!(repo, manifest, polo, fingerprint, content_sha256, now) do
    exists? =
      repo.exists?(
        from event in SystemEvent,
          where:
            event.request_id == ^manifest.operation_id and
              event.action == "bootstrap.foundation_applied"
      )

    unless exists? do
      Audit.record_system!(repo, RequestContext.new!(manifest.operation_id), %{
        action: "bootstrap.foundation_applied",
        resource_type: "polo",
        resource_id: polo.id,
        metadata: %{
          "fingerprint" => fingerprint,
          "legal_content_sha256" => Base.encode16(content_sha256, case: :lower),
          "polo_slug" => manifest.polo.slug
        },
        occurred_at: now
      })
    end

    :ok
  end

  defp ensure_record!(repo, resource, query, new_record, expected) do
    case repo.one(query) do
      nil -> {repo.insert!(new_record), true}
      record -> {assert_expected!(repo, resource, record, expected), false}
    end
  end

  defp assert_expected!(repo, resource, record, expected) do
    differing =
      expected
      |> Enum.reject(fn {field, value} -> Map.fetch!(record, field) == value end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if differing == [], do: record, else: rollback_drift!(repo, resource, differing)
  end

  defp rollback_drift!(repo, resource, fields) do
    repo.rollback({:bootstrap_drift, resource, Enum.sort(fields)})
  end

  defp database_now(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp timestamps(now), do: %{inserted_at: now, updated_at: now}

  defp open_range(lower) do
    %Postgrex.Range{
      lower: lower,
      upper: :unbound,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp sha256(content), do: :crypto.hash(:sha256, content)
end
