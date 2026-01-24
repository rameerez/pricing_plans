# frozen_string_literal: true

require "test_helper"

class PlanOwnerScopesTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        limits :projects, to: 1, after_limit: :grace_then_block, grace: 7.days
      end
      config.plan :pro do
        limits :projects, to: 10
      end
    end
    Project.send(:limited_by_pricing_plans, :projects, plan_owner: :organization) if Project.respond_to?(:limited_by_pricing_plans)
  end

  # === Class-level scopes for admin dashboards ===
  # These scopes allow querying plan owners by their limits status,
  # useful for admin dashboards to find "organizations needing attention"

  test ".with_exceeded_limits returns plan owners with any exceeded limit" do
    ok_org = Organization.create!(name: "OK Org")
    exceeded_org = Organization.create!(name: "Exceeded Org")

    # Create enforcement state for exceeded org
    PricingPlans::EnforcementState.create!(
      plan_owner: exceeded_org,
      limit_key: "projects",
      exceeded_at: 1.day.ago
    )

    result = Organization.with_exceeded_limits
    assert_includes result, exceeded_org
    assert_not_includes result, ok_org
  end

  test ".with_blocked_limits returns plan owners that are blocked" do
    exceeded_org = Organization.create!(name: "Exceeded Org")
    blocked_org = Organization.create!(name: "Blocked Org")
    ok_org = Organization.create!(name: "OK Org")

    # Exceeded but not blocked
    PricingPlans::EnforcementState.create!(
      plan_owner: exceeded_org,
      limit_key: "projects",
      exceeded_at: 1.day.ago,
      blocked_at: nil
    )

    # Blocked
    PricingPlans::EnforcementState.create!(
      plan_owner: blocked_org,
      limit_key: "projects",
      exceeded_at: 8.days.ago,
      blocked_at: 1.day.ago
    )

    result = Organization.with_blocked_limits
    assert_includes result, blocked_org
    assert_not_includes result, exceeded_org
    assert_not_includes result, ok_org
  end

  test ".in_grace_period returns plan owners with exceeded but not blocked limits" do
    exceeded_org = Organization.create!(name: "Exceeded Org")
    blocked_org = Organization.create!(name: "Blocked Org")
    ok_org = Organization.create!(name: "OK Org")

    # In grace period (exceeded but not blocked)
    PricingPlans::EnforcementState.create!(
      plan_owner: exceeded_org,
      limit_key: "projects",
      exceeded_at: 1.day.ago,
      blocked_at: nil
    )

    # Blocked (past grace period)
    PricingPlans::EnforcementState.create!(
      plan_owner: blocked_org,
      limit_key: "projects",
      exceeded_at: 8.days.ago,
      blocked_at: 1.day.ago
    )

    result = Organization.in_grace_period
    assert_includes result, exceeded_org
    assert_not_includes result, blocked_org
    assert_not_includes result, ok_org
  end

  test ".within_all_limits returns plan owners with no exceeded limits" do
    ok_org = Organization.create!(name: "OK Org")
    exceeded_org = Organization.create!(name: "Exceeded Org")

    PricingPlans::EnforcementState.create!(
      plan_owner: exceeded_org,
      limit_key: "projects",
      exceeded_at: 1.day.ago
    )

    result = Organization.within_all_limits
    assert_includes result, ok_org
    assert_not_includes result, exceeded_org
  end

  test ".needing_attention returns plan owners with any exceeded or blocked limit" do
    ok_org = Organization.create!(name: "OK Org")
    exceeded_org = Organization.create!(name: "Exceeded Org")
    blocked_org = Organization.create!(name: "Blocked Org")

    PricingPlans::EnforcementState.create!(
      plan_owner: exceeded_org,
      limit_key: "projects",
      exceeded_at: 1.day.ago
    )

    PricingPlans::EnforcementState.create!(
      plan_owner: blocked_org,
      limit_key: "projects",
      exceeded_at: 8.days.ago,
      blocked_at: 1.day.ago
    )

    result = Organization.needing_attention
    assert_includes result, exceeded_org
    assert_includes result, blocked_org
    assert_not_includes result, ok_org
  end

  test "scopes work with multiple enforcement states per owner" do
    org1 = Organization.create!(name: "Org With Exceeded")
    org2 = Organization.create!(name: "Org With Blocked")

    # One org exceeded
    PricingPlans::EnforcementState.create!(
      plan_owner: org1,
      limit_key: "projects",
      exceeded_at: 1.day.ago
    )

    # Another org blocked
    PricingPlans::EnforcementState.create!(
      plan_owner: org2,
      limit_key: "projects",
      exceeded_at: 8.days.ago,
      blocked_at: 1.day.ago
    )

    # Should find both as exceeded (blocked implies exceeded)
    assert_equal 2, Organization.with_exceeded_limits.count
    # Only one is blocked
    assert_equal 1, Organization.with_blocked_limits.count
    # Both need attention
    assert_equal 2, Organization.needing_attention.count
  end

  test "scopes are chainable with other ActiveRecord methods" do
    exceeded_org = Organization.create!(name: "Exceeded Org")
    PricingPlans::EnforcementState.create!(
      plan_owner: exceeded_org,
      limit_key: "projects",
      exceeded_at: 1.day.ago
    )

    # Chainable with where, order, limit, etc.
    result = Organization.with_exceeded_limits.where(name: "Exceeded Org").order(:created_at).limit(10)
    assert_includes result, exceeded_org
  end
end
