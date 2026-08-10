defmodule Clubeira.Redemptions.Eligibility do
  @moduledoc """
  Locks an entitlement allocation and evaluates its persisted redemption rules.
  """

  alias Clubeira.Redemptions.ConfirmedRequest
  alias Clubeira.Tenancy.Scope

  @reason_codes %{
    "validation_point_unavailable" => :validation_point_unavailable,
    "place_unavailable" => :place_unavailable,
    "device_unavailable" => :device_unavailable,
    "actor_not_entitled" => :actor_not_entitled,
    "contract_inactive" => :contract_inactive,
    "cycle_inactive" => :cycle_inactive,
    "entitlement_configuration_invalid" => :entitlement_configuration_invalid,
    "offer_inactive" => :offer_inactive,
    "offer_not_available_at_place" => :offer_not_available_at_place,
    "outside_availability_window" => :outside_availability_window,
    "offer_blackout" => :offer_blackout,
    "allocation_not_valid_at_place" => :allocation_not_valid_at_place,
    "device_not_authorized" => :device_not_authorized,
    "entitlement_exhausted" => :entitlement_exhausted
  }

  @query """
  SELECT
    allocation.id,
    allocation.benefit_package_item_id,
    allocation.entitlement_scope_id,
    allocation.allocation_kind,
    allocation.available_units,
    subject.access_contract_id,
    subject.contract_beneficiary_id,
    validation.id,
    validation.polo_place_id,
    device.id,
    CASE
      WHEN validation.id IS NULL OR validation.status <> 'active'
        THEN 'validation_point_unavailable'
      WHEN target_place.id IS NULL
        OR target_place.status <> 'active'
        OR NOT (target_place.participation_during @> $5::timestamptz)
        THEN 'place_unavailable'
      WHEN device.id IS NULL OR device.status <> 'active'
        THEN 'device_unavailable'
      WHEN NOT (
        (subject.subject_kind = 'contract' AND contract.purchaser_user_id = $3)
        OR EXISTS (
          SELECT 1
          FROM contract_beneficiaries AS beneficiary
          JOIN user_person_links AS person_link
            ON person_link.person_id = beneficiary.person_id
          WHERE beneficiary.polo_id = allocation.polo_id
            AND beneficiary.access_contract_id = subject.access_contract_id
            AND beneficiary.status = 'active'
            AND beneficiary.valid_during @> $5::timestamptz
            AND person_link.user_id = $3
            AND person_link.status = 'active'
            AND (
              subject.subject_kind = 'contract'
              OR beneficiary.id = subject.contract_beneficiary_id
            )
        )
      )
        THEN 'actor_not_entitled'
      WHEN NOT (
        contract.status = 'active'
        OR (
          contract.status = 'past_due'
          AND policy.delinquency_mode = 'grace_period'
          AND cycle.delinquency_grace_until >= $5::timestamptz
        )
      )
        OR (contract.starts_at IS NOT NULL AND contract.starts_at > $5::timestamptz)
        OR (contract.ends_at IS NOT NULL AND contract.ends_at <= $5::timestamptz)
        THEN 'contract_inactive'
      WHEN cycle.status <> 'active'
        OR NOT (cycle.benefits_during @> $5::timestamptz)
        THEN 'cycle_inactive'
      WHEN item.benefit_package_version_id <> cycle.benefit_package_version_id
        OR allocation.entitlement_scope_id <> item.entitlement_scope_id
        OR allocation.allocation_kind <> item.consumption_unit
        THEN 'entitlement_configuration_invalid'
      WHEN offer.status <> 'active'
        OR offer_version.status <> 'published'
        OR NOT (offer_version.effective_during @> $5::timestamptz)
        THEN 'offer_inactive'
      WHEN NOT EXISTS (
        SELECT 1
        FROM benefit_offer_version_places AS offer_place
        WHERE offer_place.polo_id = allocation.polo_id
          AND offer_place.benefit_offer_version_id = item.benefit_offer_version_id
          AND offer_place.polo_place_id = validation.polo_place_id
      )
        THEN 'offer_not_available_at_place'
      WHEN EXISTS (
        SELECT 1
        FROM benefit_offer_availability_windows AS availability
        WHERE availability.polo_id = allocation.polo_id
          AND availability.benefit_offer_version_id = item.benefit_offer_version_id
      )
        AND NOT EXISTS (
          SELECT 1
          FROM benefit_offer_availability_windows AS availability
          WHERE availability.polo_id = allocation.polo_id
            AND availability.benefit_offer_version_id = item.benefit_offer_version_id
            AND availability.weekday = EXTRACT(
              ISODOW FROM ($5::timestamptz AT TIME ZONE polo.timezone)
            )
            AND ($5::timestamptz AT TIME ZONE polo.timezone)::time >= availability.starts_at_local
            AND ($5::timestamptz AT TIME ZONE polo.timezone)::time < availability.ends_at_local
        )
        THEN 'outside_availability_window'
      WHEN EXISTS (
        SELECT 1
        FROM benefit_offer_blackout_periods AS blackout
        WHERE blackout.polo_id = allocation.polo_id
          AND blackout.benefit_offer_version_id = item.benefit_offer_version_id
          AND blackout.blackout_during @> $5::timestamptz
      )
        THEN 'offer_blackout'
      WHEN NOT (
        (
          allocation.allocation_kind = 'per_place'
          AND allocation.polo_place_id = validation.polo_place_id
        )
        OR (
          allocation.allocation_kind = 'shared_scope'
          AND EXISTS (
            SELECT 1
            FROM entitlement_scope_places AS scope_place
            WHERE scope_place.polo_id = allocation.polo_id
              AND scope_place.entitlement_scope_id = allocation.entitlement_scope_id
              AND scope_place.polo_place_id = validation.polo_place_id
          )
        )
      )
        THEN 'allocation_not_valid_at_place'
      WHEN NOT EXISTS (
        SELECT 1
        FROM user_device_authorizations AS user_device
        WHERE user_device.user_id = $3
          AND user_device.device_installation_id = $4
          AND user_device.status = 'active'
      )
        THEN 'device_not_authorized'
      WHEN policy.redemption_device_policy = 'authorized_devices'
        AND NOT EXISTS (
          SELECT 1
          FROM contract_redemption_devices AS contract_device
          WHERE contract_device.polo_id = allocation.polo_id
            AND contract_device.access_contract_id = subject.access_contract_id
            AND contract_device.device_installation_id = $4
            AND contract_device.status = 'active'
            AND contract_device.valid_during @> $5::timestamptz
            AND (
              contract_device.contract_beneficiary_id IS NULL
              OR contract_device.contract_beneficiary_id = subject.contract_beneficiary_id
              OR (
                subject.subject_kind = 'contract'
                AND EXISTS (
                  SELECT 1
                  FROM contract_beneficiaries AS device_beneficiary
                  JOIN user_person_links AS device_person_link
                    ON device_person_link.person_id = device_beneficiary.person_id
                  WHERE device_beneficiary.id = contract_device.contract_beneficiary_id
                    AND device_beneficiary.status = 'active'
                    AND device_beneficiary.valid_during @> $5::timestamptz
                    AND device_person_link.user_id = $3
                    AND device_person_link.status = 'active'
                )
              )
            )
        )
        THEN 'device_not_authorized'
      WHEN allocation.available_units < 1
        THEN 'entitlement_exhausted'
      ELSE NULL
    END AS rejection_reason
  FROM entitlement_allocations AS allocation
  JOIN cycle_entitlement_subjects AS subject
    ON subject.id = allocation.cycle_entitlement_subject_id
    AND subject.polo_id = allocation.polo_id
  JOIN benefit_cycles AS cycle
    ON cycle.id = subject.benefit_cycle_id
    AND cycle.polo_id = allocation.polo_id
    AND cycle.access_contract_id = subject.access_contract_id
  JOIN access_contracts AS contract
    ON contract.id = subject.access_contract_id
    AND contract.polo_id = allocation.polo_id
  JOIN polo_policy_versions AS policy
    ON policy.id = cycle.polo_policy_version_id
    AND policy.polo_id = allocation.polo_id
  JOIN benefit_package_items AS item
    ON item.id = allocation.benefit_package_item_id
    AND item.polo_id = allocation.polo_id
  JOIN benefit_offer_versions AS offer_version
    ON offer_version.id = item.benefit_offer_version_id
    AND offer_version.polo_id = allocation.polo_id
  JOIN benefit_offers AS offer
    ON offer.id = offer_version.benefit_offer_id
    AND offer.polo_id = allocation.polo_id
  JOIN polos AS polo
    ON polo.id = allocation.polo_id
  LEFT JOIN validation_points AS validation
    ON validation.id = $2
    AND validation.polo_id = allocation.polo_id
  LEFT JOIN polo_places AS target_place
    ON target_place.id = validation.polo_place_id
    AND target_place.polo_id = allocation.polo_id
  LEFT JOIN device_installations AS device
    ON device.id = $4
  WHERE allocation.id = $1
    AND allocation.polo_id = $6
  FOR UPDATE OF allocation
  """

  @enforce_keys ~w(
    allocation_id
    benefit_package_item_id
    entitlement_scope_id
    allocation_kind
    available_units
    access_contract_id
  )a
  defstruct @enforce_keys ++
              [
                :contract_beneficiary_id,
                :validation_point_id,
                :polo_place_id,
                :device_installation_id,
                :reason
              ]

  @type reason ::
          :validation_point_unavailable
          | :place_unavailable
          | :device_unavailable
          | :actor_not_entitled
          | :contract_inactive
          | :cycle_inactive
          | :entitlement_configuration_invalid
          | :offer_inactive
          | :offer_not_available_at_place
          | :outside_availability_window
          | :offer_blackout
          | :allocation_not_valid_at_place
          | :device_not_authorized
          | :entitlement_exhausted
          | nil

  @type t :: %__MODULE__{
          allocation_id: Ecto.UUID.t(),
          benefit_package_item_id: Ecto.UUID.t(),
          entitlement_scope_id: Ecto.UUID.t(),
          allocation_kind: String.t(),
          available_units: non_neg_integer(),
          access_contract_id: Ecto.UUID.t(),
          contract_beneficiary_id: Ecto.UUID.t() | nil,
          validation_point_id: Ecto.UUID.t() | nil,
          polo_place_id: Ecto.UUID.t() | nil,
          device_installation_id: Ecto.UUID.t() | nil,
          reason: reason()
        }

  @spec lock(module(), Scope.t(), ConfirmedRequest.t(), DateTime.t()) ::
          {:ok, t()} | {:error, :entitlement_not_found}
  def lock(repo, %Scope{} = scope, %ConfirmedRequest{} = request, now) do
    parameters = [
      dump_uuid!(request.entitlement_allocation_id),
      dump_uuid!(request.validation_point_id),
      dump_uuid!(scope.actor_user_id),
      dump_uuid!(request.device_installation_id),
      now,
      dump_uuid!(scope.polo_id)
    ]

    case repo.query!(@query, parameters).rows do
      [row] -> {:ok, from_row(row)}
      [] -> {:error, :entitlement_not_found}
    end
  end

  @spec recordable_attempt?(t()) :: boolean()
  def recordable_attempt?(%__MODULE__{} = eligibility) do
    not is_nil(eligibility.validation_point_id) and
      not is_nil(eligibility.polo_place_id) and
      not is_nil(eligibility.device_installation_id)
  end

  defp from_row([
         allocation_id,
         package_item_id,
         scope_id,
         allocation_kind,
         available_units,
         access_contract_id,
         beneficiary_id,
         validation_point_id,
         polo_place_id,
         device_id,
         reason
       ]) do
    %__MODULE__{
      allocation_id: load_uuid!(allocation_id),
      benefit_package_item_id: load_uuid!(package_item_id),
      entitlement_scope_id: load_uuid!(scope_id),
      allocation_kind: allocation_kind,
      available_units: available_units,
      access_contract_id: load_uuid!(access_contract_id),
      contract_beneficiary_id: load_optional_uuid!(beneficiary_id),
      validation_point_id: load_optional_uuid!(validation_point_id),
      polo_place_id: load_optional_uuid!(polo_place_id),
      device_installation_id: load_optional_uuid!(device_id),
      reason: reason_atom(reason)
    }
  end

  defp reason_atom(nil), do: nil
  defp reason_atom(reason), do: Map.fetch!(@reason_codes, reason)

  defp dump_uuid!(uuid), do: Ecto.UUID.dump!(uuid)
  defp load_uuid!(uuid), do: Ecto.UUID.load!(uuid)
  defp load_optional_uuid!(nil), do: nil
  defp load_optional_uuid!(uuid), do: load_uuid!(uuid)
end
