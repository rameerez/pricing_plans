# frozen_string_literal: true

require "test_helper"

# COMPREHENSIVE TESTS: Secure-by-Default Behavior for Undefined Limits
#
# This test file documents and enforces the BREAKING CHANGE introduced to make
# undefined limits default to 0 (blocked) instead of :unlimited (fail-open).
#
# PHILOSOPHY: Fail-closed (secure) by default
# - Features: blocked unless explicitly allowed with `allows`
# - Limits: blocked unless explicitly defined with `limit` or `unlimited`
#
# This consistency ensures developers must explicitly grant access, preventing
# security issues from forgotten/undefined limits.
#
# REAL-WORLD USE CASE: Hidden unsubscribed plans for all-paid products
# Example: demobusiness.com wants unsubscribed users to have zero access without
# seeing an "Unsubscribed" plan on the pricing page. The hidden default plan
# achieves this elegantly without inadvertently granting unlimited access.

class SecureByDefaultTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
  end

  # ========================================
  # SECTION 1: UNDEFINED LIMITS = BLOCKED
  # ========================================

  def test_undefined_limits_default_to_zero_not_unlimited
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :starter do
        price 10
        default!
        # No limits defined at all
      end
    end

    org = Organization.create!(name: "Test Org")
    PricingPlans::PlanResolver.assign_plan_manually!(org, :starter)

    # SECURITY: Undefined limits are BLOCKED (0), not unlimited
    assert_equal 0, org.plan_limit_remaining(:projects)
    assert_equal 0, org.plan_limit_remaining(:api_calls)
    assert_equal 0, org.plan_limit_remaining(:storage)
    assert_equal 0, org.plan_limit_remaining(:any_undefined_limit)

    # within_limit? returns false for undefined limits
    refute org.within_plan_limits?(:projects)
    refute org.within_plan_limits?(:api_calls, by: 1)
    refute org.within_plan_limits?(:storage, by: 100)
  end

  def test_undefined_limits_match_undefined_features_behavior
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :basic do
        price 5
        default!
        # No features defined
        # No limits defined
      end
    end

    org = Organization.create!(name: "Test Org")
    PricingPlans::PlanResolver.assign_plan_manually!(org, :basic)

    # CONSISTENCY: Both features and limits are fail-closed (blocked by default)

    # Undefined features are blocked
    refute org.plan_allows?(:advanced_analytics), "Undefined features should be blocked"
    refute org.plan_allows?(:priority_support), "Undefined features should be blocked"
    refute org.plan_allows?(:api_access), "Undefined features should be blocked"

    # Undefined limits are blocked (matching behavior)
    refute org.within_plan_limits?(:projects), "Undefined limits should be blocked"
    refute org.within_plan_limits?(:users), "Undefined limits should be blocked"
    refute org.within_plan_limits?(:storage), "Undefined limits should be blocked"

    # This is SECURE BY DEFAULT - developers must explicitly grant access
  end

  def test_explicit_unlimited_still_works
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :enterprise do
        price 999
        default!
        unlimited :projects, :users, :storage  # Explicit unlimited
        limit :api_calls, to: 100_000, per: :month  # Explicit limit
        # :downloads undefined - should be blocked
      end
    end

    org = Organization.create!(name: "Enterprise Org")
    PricingPlans::PlanResolver.assign_plan_manually!(org, :enterprise)

    # Explicit unlimited works
    assert_equal :unlimited, org.plan_limit_remaining(:projects)
    assert_equal :unlimited, org.plan_limit_remaining(:users)
    assert_equal :unlimited, org.plan_limit_remaining(:storage)
    assert org.within_plan_limits?(:projects, by: 999_999)

    # Explicit limit works
    assert_equal 100_000, org.plan_limit_remaining(:api_calls)

    # Undefined limit is blocked
    assert_equal 0, org.plan_limit_remaining(:downloads)
    refute org.within_plan_limits?(:downloads)
  end

  # ========================================
  # SECTION 2: REAL-WORLD USE CASE
  # Hidden Unsubscribed Plan (demobusiness)
  # ========================================

  def test_demobusiness_use_case_hidden_unsubscribed_plan_blocks_everything
    # REAL SCENARIO: All-paid product where unsubscribed users should have zero access
    # The unsubscribed plan is hidden (not shown on pricing page) and blocks everything by default
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      # Hidden default plan - no limits defined, everything blocked by default
      config.plan :unsubscribed do
        name "Pending Subscription"
        description "Subscribe to a plan to get started"
        price 0
        hidden!
        default!
        # CRITICAL: No limits defined here
        # Before breaking change: would have been unlimited (security issue!)
        # After breaking change: everything is blocked (secure!)
      end

      config.plan :starter do
        name "Starter"
        price 29
        limit :projects, to: 10
        limit :downloads, to: 1000, per: :month
        limit :storage, to: 5.gigabytes
        highlighted!
      end

      config.plan :pro do
        name "Pro"
        price 99
        limit :projects, to: 100
        unlimited :downloads
        limit :storage, to: 100.gigabytes
      end
    end

    # New user signs up (no subscription yet)
    new_user_org = Organization.create!(name: "New User Org")

    # Should be on hidden :unsubscribed plan (default)
    assert_equal :unsubscribed, new_user_org.current_pricing_plan.key
    assert new_user_org.current_pricing_plan.hidden?

    # SECURITY: All limits are blocked (0) since none were defined
    assert_equal 0, new_user_org.plan_limit_remaining(:projects), "Unsubscribed users should have 0 projects"
    assert_equal 0, new_user_org.plan_limit_remaining(:downloads), "Unsubscribed users should have 0 downloads"
    assert_equal 0, new_user_org.plan_limit_remaining(:storage), "Unsubscribed users should have 0 storage"

    # Cannot perform any actions
    refute new_user_org.within_plan_limits?(:projects), "Cannot create projects"
    refute new_user_org.within_plan_limits?(:downloads, by: 1), "Cannot download"
    refute new_user_org.within_plan_limits?(:storage, by: 1.megabyte), "Cannot use storage"

    # :unsubscribed plan is NOT shown on pricing page
    pricing_plans = PricingPlans.for_pricing(plan_owner: new_user_org)
    assert_equal 2, pricing_plans.size
    assert_equal [:starter, :pro], pricing_plans.map { |p| p[:key] }
    refute pricing_plans.any? { |p| p[:key] == :unsubscribed }

    # After subscribing to starter, limits become available
    PricingPlans::PlanResolver.assign_plan_manually!(new_user_org, :starter)
    assert_equal 10, new_user_org.plan_limit_remaining(:projects)
    assert_equal 1000, new_user_org.plan_limit_remaining(:downloads)
    assert new_user_org.within_plan_limits?(:projects)
  end

  def test_forgotten_limit_is_blocked_not_unlimited
    # SECURITY SCENARIO: Developer forgets to define a limit in a plan
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :premium do
        price 49
        default!
        limit :projects, to: 50
        limit :users, to: 10
        # OOPS: Developer forgot to define :api_calls limit!
        # Before: Would have been :unlimited (security issue!)
        # After: Is blocked (secure!)
      end
    end

    org = Organization.create!(name: "Premium Org")
    PricingPlans::PlanResolver.assign_plan_manually!(org, :premium)

    # Defined limits work
    assert_equal 50, org.plan_limit_remaining(:projects)
    assert_equal 10, org.plan_limit_remaining(:users)

    # Forgotten limit is BLOCKED, not unlimited
    assert_equal 0, org.plan_limit_remaining(:api_calls), "Forgotten limits should be blocked"
    refute org.within_plan_limits?(:api_calls), "Forgotten limits should block access"
  end

  # ========================================
  # SECTION 3: CONTROLLER ENFORCEMENT
  # ========================================

  def test_controller_guards_block_undefined_limits
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :basic do
        price 10
        default!
        limit :projects, to: 5
        # :exports undefined
      end
    end

    org = Organization.create!(name: "Test Org")
    PricingPlans::PlanResolver.assign_plan_manually!(org, :basic)

    # Simulate controller context
    controller = MockController.new
    controller.instance_variable_set(:@org, org)
    controller.extend(PricingPlans::ControllerGuards)

    # Defined limit - should work
    result_projects = controller.require_plan_limit!(:projects, plan_owner: org)
    assert result_projects.within?, "Defined limits should allow access when within limit"

    # Undefined limit - should be BLOCKED
    result_exports = controller.require_plan_limit!(:exports, plan_owner: org)
    assert result_exports.blocked?, "Undefined limits should block access"
    assert_match(/not configured/i, result_exports.message)
  end

  # ========================================
  # SECTION 4: MODEL VALIDATIONS
  # ========================================

  def test_model_validations_block_creation_when_limit_undefined
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :trial do
        price 0
        default!
        # No :projects limit defined
      end
    end

    org = Organization.create!(name: "Trial Org")
    PricingPlans::PlanResolver.assign_plan_manually!(org, :trial)

    # Try to create a project (which has limited_by_pricing_plans validation)
    # When limit is undefined (0), attempting to create should be blocked
    project = org.projects.build(name: "Test Project")

    # Validation should fail because remaining is 0 (undefined limit)
    refute project.valid?, "Should fail validation when limit is undefined (0 remaining)"

    # The error comes from the limit validation
    assert project.errors.any?, "Should have validation errors"
    assert_includes project.errors.full_messages.join.downcase, "projects", "Error should mention projects limit"
  end

  def test_model_validations_allow_creation_when_limit_defined
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :trial do
        price 0
        default!
        limit :projects, to: 3
      end
    end

    org = Organization.create!(name: "Trial Org")
    PricingPlans::PlanResolver.assign_plan_manually!(org, :trial)

    # Should succeed when limit is defined and not exceeded
    project = org.projects.create!(name: "Test Project")
    assert project.persisted?, "Should allow creation when limit is defined and within limit"
  end

  # ========================================
  # SECTION 5: EDGE CASES & SECURITY
  # ========================================

  def test_partially_defined_limits_only_allow_defined_ones
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :mixed do
        price 20
        default!
        limit :projects, to: 10  # Defined
        unlimited :users  # Defined as unlimited
        # :api_calls undefined
        # :storage undefined
      end
    end

    org = Organization.create!(name: "Mixed Org")
    PricingPlans::PlanResolver.assign_plan_manually!(org, :mixed)

    # Defined limit works
    assert_equal 10, org.plan_limit_remaining(:projects)
    assert org.within_plan_limits?(:projects)

    # Defined unlimited works
    assert_equal :unlimited, org.plan_limit_remaining(:users)
    assert org.within_plan_limits?(:users, by: 999_999)

    # Undefined limits are blocked
    assert_equal 0, org.plan_limit_remaining(:api_calls)
    assert_equal 0, org.plan_limit_remaining(:storage)
    refute org.within_plan_limits?(:api_calls)
    refute org.within_plan_limits?(:storage)
  end

  def test_no_plan_assigned_defaults_to_blocked
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :starter do
        price 10
        default!
        limit :projects, to: 5
        # :api_calls undefined
      end
    end

    org = Organization.create!(name: "No Plan Org")
    # Org automatically gets default plan (:starter)

    # Defined limit in default plan works
    assert_equal 5, org.plan_limit_remaining(:projects)

    # Undefined limits are still blocked even in default plan
    assert_equal 0, org.plan_limit_remaining(:api_calls)
    refute org.within_plan_limits?(:api_calls)
  end

  def test_suggest_next_plan_skips_hidden_unsubscribed_plan
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :unsubscribed do
        price 0
        hidden!
        default!
        # No limits defined
      end

      config.plan :starter do
        price 29
        limit :projects, to: 10
      end

      config.plan :pro do
        price 99
        limit :projects, to: 100
      end
    end

    org = Organization.create!(name: "New Org")
    # Org is on :unsubscribed (hidden, default)

    # suggest_next_plan_for should suggest :starter, not stay on hidden :unsubscribed
    suggested = PricingPlans.suggest_next_plan_for(org, keys: [:projects])
    assert_equal :starter, suggested.key, "Should suggest visible plan, not hidden unsubscribed"
    refute suggested.hidden?
  end

  # ========================================
  # SECTION 6: COMPARISON TABLE
  # (Documented as test for future reference)
  # ========================================

  def test_behavior_comparison_table_undefined_vs_defined
    # This test documents expected behavior across all scenarios
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :comprehensive do
        price 50
        default!
        # Features
        allows :feature_a  # Defined feature: allowed
        disallows :feature_b  # Defined feature: disallowed
        # :feature_c undefined

        # Limits
        limit :limit_a, to: 10  # Defined limit
        unlimited :limit_b  # Defined as unlimited
        limit :limit_c, to: 0  # Defined as zero
        # :limit_d undefined
      end
    end

    org = Organization.create!(name: "Comprehensive Org")
    PricingPlans::PlanResolver.assign_plan_manually!(org, :comprehensive)

    # FEATURES
    assert org.plan_allows?(:feature_a), "Defined allowed feature = true"
    refute org.plan_allows?(:feature_b), "Defined disallowed feature = false"
    refute org.plan_allows?(:feature_c), "Undefined feature = false (fail-closed)"

    # LIMITS
    assert_equal 10, org.plan_limit_remaining(:limit_a), "Defined limit = limit value"
    assert_equal :unlimited, org.plan_limit_remaining(:limit_b), "Defined unlimited = :unlimited"
    assert_equal 0, org.plan_limit_remaining(:limit_c), "Defined as 0 = 0"
    assert_equal 0, org.plan_limit_remaining(:limit_d), "Undefined limit = 0 (fail-closed)"

    # WITHIN LIMITS
    assert org.within_plan_limits?(:limit_a), "Within defined limit = true"
    assert org.within_plan_limits?(:limit_b), "Within unlimited = true"
    refute org.within_plan_limits?(:limit_c), "Within limit of 0 = false"
    refute org.within_plan_limits?(:limit_d), "Within undefined limit = false"

    # BEHAVIOR TABLE (for documentation):
    # ┌─────────────────────┬──────────────────┬─────────────────┬──────────────────┐
    # │ Type                │ Defined: Allowed │ Defined: Blocked│ Undefined        │
    # ├─────────────────────┼──────────────────┼─────────────────┼──────────────────┤
    # │ Features            │ allows :x → true │ disallows :x    │ false (blocked)  │
    # │                     │                  │ → false         │                  │
    # ├─────────────────────┼──────────────────┼─────────────────┼──────────────────┤
    # │ Limits              │ limit :x, to: N  │ limit :x, to: 0 │ 0 (blocked)      │
    # │                     │ → N              │ → 0             │                  │
    # │                     │ unlimited :x     │                 │                  │
    # │                     │ → :unlimited     │                 │                  │
    # └─────────────────────┴──────────────────┴─────────────────┴──────────────────┘
    #
    # KEY INSIGHT: Both features and limits are FAIL-CLOSED (secure by default)
  end

  # ========================================
  # SECTION 7: MIGRATION SCENARIOS
  # ========================================

  def test_migration_from_implicit_unlimited_to_explicit
    # SCENARIO: Existing app had undefined limits that were implicitly unlimited
    # MIGRATION: Must add explicit `unlimited` for those limits
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :legacy do
        price 99
        default!
        limit :projects, to: 100
        # Before: :api_calls was undefined → :unlimited (implicit)
        # After migration: Must be explicit
        unlimited :api_calls  # ADDED: Make implicit unlimited explicit
      end
    end

    org = Organization.create!(name: "Legacy Org")
    PricingPlans::PlanResolver.assign_plan_manually!(org, :legacy)

    # After migration, :api_calls is still unlimited (but explicit)
    assert_equal :unlimited, org.plan_limit_remaining(:api_calls)
    assert org.within_plan_limits?(:api_calls, by: 999_999)
  end

  def test_new_restrictive_plan_benefits_from_secure_default
    # SCENARIO: New restrictive plan wants to block everything except specific limits
    # BENEFIT: No need to define every limit as 0, just define the allowed ones
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :restrictive do
        price 0
        default!
        limit :projects, to: 1  # Only allow 1 project
        # Everything else undefined → blocked automatically
        # Before: Would need to define every limit as 0
        # After: Secure by default!
      end
    end

    org = Organization.create!(name: "Restrictive Org")
    PricingPlans::PlanResolver.assign_plan_manually!(org, :restrictive)

    # Defined limit works
    assert_equal 1, org.plan_limit_remaining(:projects)

    # Everything else is blocked automatically
    assert_equal 0, org.plan_limit_remaining(:users)
    assert_equal 0, org.plan_limit_remaining(:api_calls)
    assert_equal 0, org.plan_limit_remaining(:storage)
    assert_equal 0, org.plan_limit_remaining(:downloads)
    assert_equal 0, org.plan_limit_remaining(:exports)
    # ... no need to define every possible limit as 0!
  end

  # ========================================
  # HELPER CLASS
  # ========================================

  class MockController
    attr_accessor :org

    def pricing_plans_plan_owner
      @org
    end

    def respond_to?(method_name)
      [:pricing_plans_plan_owner].include?(method_name) || super
    end
  end
end
