# frozen_string_literal: true

require "test_helper"

class PlanOwnerIdentityTest < ActiveSupport::TestCase
  def test_overrides_use_the_polymorphic_base_class_for_sti_owners
    owner = EnterpriseOrganization.create!(name: "STI Override")

    assignment = owner.override_pricing_plan!(:pro, source: "admin")

    assert_equal Organization.polymorphic_name, assignment.plan_owner_type
    assert_predicate owner, :pricing_plan_overridden?
    assert_equal :pro, owner.current_pricing_plan.key

    owner.clear_pricing_plan_override!

    refute_predicate owner, :pricing_plan_overridden?
  end

  def test_feature_grants_use_the_same_polymorphic_identity_for_reads_and_writes
    owner = EnterpriseOrganization.create!(name: "STI Grant")

    grant = owner.grant_feature!(:beta, source: "test")

    assert_equal Organization.polymorphic_name, grant.plan_owner_type
    assert owner.feature_granted?(:beta)
    assert_equal [grant], owner.feature_grants.to_a
  end

  def test_admin_scopes_use_the_polymorphic_identity
    owner = EnterpriseOrganization.create!(name: "STI Scope")
    PricingPlans::EnforcementState.create!(
      plan_owner: owner,
      limit_key: "projects",
      exceeded_at: Time.current
    )

    assert_includes EnterpriseOrganization.with_exceeded_limits, owner
  end
end
