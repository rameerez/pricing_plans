# frozen_string_literal: true

require "test_helper"

class EnforcementStateTest < ActiveSupport::TestCase
  def setup
    super  # This calls the test helper setup which configures plans
    @org = create_organization
  end

  def test_factory_creates_valid_state
    state = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects"
    )

    assert state.valid?
    assert_equal @org, state.plan_owner
    assert_equal "projects", state.limit_key
  end

  def test_validation_requires_limit_key
    state = PricingPlans::EnforcementState.new(plan_owner: @org)

    refute state.valid?
    assert state.errors[:limit_key].any?
  end

  def test_uniqueness_validation
    PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects"
    )

    duplicate = PricingPlans::EnforcementState.new(
      plan_owner: @org,
      limit_key: "projects"
    )

    refute duplicate.valid?
    assert duplicate.errors[:limit_key].any?

    differrent_limit_key = PricingPlans::EnforcementState.new(
      plan_owner: @org,
      limit_key: "members"
    )

    assert differrent_limit_key.valid?
  end

  def test_exceeded_scope_and_method
    exceeded_state = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects",
      exceeded_at: Time.current
    )

    not_exceeded_state = PricingPlans::EnforcementState.create!(
      plan_owner: create_organization,
      limit_key: "projects"
    )

    assert_includes PricingPlans::EnforcementState.exceeded, exceeded_state
    refute_includes PricingPlans::EnforcementState.exceeded, not_exceeded_state

    assert exceeded_state.exceeded?
    refute not_exceeded_state.exceeded?
  end

  def test_blocked_scope_and_method
    blocked_state = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects",
      exceeded_at: Time.current,
      blocked_at: Time.current
    )

    not_blocked_state = PricingPlans::EnforcementState.create!(
      plan_owner: create_organization,
      limit_key: "projects",
      exceeded_at: Time.current
    )

    assert_includes PricingPlans::EnforcementState.blocked, blocked_state
    refute_includes PricingPlans::EnforcementState.blocked, not_blocked_state

    assert blocked_state.blocked?
    refute not_blocked_state.blocked?
  end

  def test_in_grace_scope_and_method
    in_grace_state = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects",
      exceeded_at: Time.current
    )

    blocked_state = PricingPlans::EnforcementState.create!(
      plan_owner: create_organization,
      limit_key: "projects",
      exceeded_at: Time.current,
      blocked_at: Time.current
    )

    not_exceeded_state = PricingPlans::EnforcementState.create!(
      plan_owner: create_organization,
      limit_key: "projects"
    )

    assert_includes PricingPlans::EnforcementState.in_grace, in_grace_state
    refute_includes PricingPlans::EnforcementState.in_grace, blocked_state
    refute_includes PricingPlans::EnforcementState.in_grace, not_exceeded_state

    assert in_grace_state.in_grace?
    refute blocked_state.in_grace?
    refute not_exceeded_state.in_grace?
  end

  def test_grace_ends_at_calculation
    state = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects",
      exceeded_at: Time.parse("2025-01-01 12:00:00 UTC"),
      data: { "grace_period" => 7.days.to_i }
    )

    expected_end = Time.parse("2025-01-08 12:00:00 UTC")
    assert_equal expected_end, state.grace_ends_at
  end

  def test_grace_ends_at_nil_without_exceeded_at
    state = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects"
    )

    assert_nil state.grace_ends_at
  end

  def test_grace_expired_when_past_grace_period
    travel_to(Time.parse("2025-01-01 12:00:00 UTC")) do
      state = PricingPlans::EnforcementState.create!(
        plan_owner: @org,
        limit_key: "projects",
        exceeded_at: Time.current,
        data: { "grace_period" => 7.days.to_i }
      )

      refute state.grace_expired?
    end

    travel_to(Time.parse("2025-01-08 12:00:01 UTC")) do
      state = PricingPlans::EnforcementState.find_by(plan_owner: @org, limit_key: "projects")
      assert state.grace_expired?
    end
  end

  def test_grace_expired_false_without_grace_end
    state = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects"
    )

    refute state.grace_expired?
  end

  def test_polymorphic_plan_owner_association
    # Test with different types of plan_owners
    state1 = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects"
    )

    # Create a different type of plan_owner for testing
    project = Project.create!(name: "Test", organization: @org)
    state2 = PricingPlans::EnforcementState.create!(
      plan_owner: project,
      limit_key: "some_limit"
    )

    assert_equal @org, state1.plan_owner
    assert_equal "Organization", state1.plan_owner_type
    assert_equal @org.id, state1.plan_owner_id

    assert_equal project, state2.plan_owner
    assert_equal "Project", state2.plan_owner_type
    assert_equal project.id, state2.plan_owner_id
  end

  def test_json_data_field_defaults_to_empty_hash
    state = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects"
    )

    assert_equal({}, state.data)
  end

  def test_json_data_field_stores_and_retrieves_data
    state = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects",
      data: {
        "grace_period" => 10.days.to_i,
        "custom_info" => "test"
      }
    )

    state.reload

    assert_equal 10.days.to_i, state.data["grace_period"]
    assert_equal "test", state.data["custom_info"]
  end
end
