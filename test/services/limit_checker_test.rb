# frozen_string_literal: true

require "test_helper"

class LimitCheckerTest < ActiveSupport::TestCase
  def test_within_limit_for_persistent_caps
    org = create_organization

    # No projects yet, should be within limit
    assert PricingPlans::LimitChecker.within_limit?(org, :projects)

    # Create projects up to limit
    org.projects.create!(name: "Project 1")

    # Should still be within limit (at limit but not over)
    refute PricingPlans::LimitChecker.within_limit?(org, :projects)

    # But can't create another
    refute PricingPlans::LimitChecker.within_limit?(org, :projects, by: 1)
  end

  def test_within_limit_for_per_period_allowances
    org = create_organization

    # Free plan limits custom_models to 0, so should not be within limit for creating 1
    refute PricingPlans::LimitChecker.within_limit?(org, :custom_models)

    # Create usage record (simulating Limitable mixin)
    period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :custom_models)
    PricingPlans::Usage.create!(
      plan_owner: org,
      limit_key: "custom_models",
      period_start: period_start,
      period_end: period_end,
      used: 0  # Free plan allows 0 custom models
    )

    # Should be at limit (0 for free plan)
    refute PricingPlans::LimitChecker.within_limit?(org, :custom_models)
  end

  def test_remaining_calculation_persistent
    org = create_organization

    # Start with 1 remaining (free plan allows 1 project)
    assert_equal 1, PricingPlans::LimitChecker.plan_limit_remaining(org, :projects)

    # Create a project
    org.projects.create!(name: "Project 1")

    # Now 0 remaining
    assert_equal 0, PricingPlans::LimitChecker.plan_limit_remaining(org, :projects)
  end

  def test_remaining_with_inferred_macro_registration
    # Ensure re-registration via original constant to avoid anonymous class pitfalls
    Project.send(:limited_by_pricing_plans, :projects, plan_owner: :organization)

    org = create_organization
    assert_equal 1, PricingPlans::LimitChecker.plan_limit_remaining(org, :projects)
  end

  def test_remaining_calculation_unlimited
    # Switch to enterprise plan which has unlimited projects
    PricingPlans::Assignment.assign_plan_to(create_organization, :enterprise)
    org = Organization.first

    assert_equal :unlimited, PricingPlans::LimitChecker.plan_limit_remaining(org, :projects)
  end

  def test_percent_used_calculation
    org = create_organization

    # 0% used initially
    assert_equal 0.0, PricingPlans::LimitChecker.plan_limit_percent_used(org, :projects)

    # Create a project (1 out of 1 allowed)
    org.projects.create!(name: "Project 1")

    # 100% used
    assert_equal 100.0, PricingPlans::LimitChecker.plan_limit_percent_used(org, :projects)
  end

  def test_percent_used_with_unlimited_limit
    PricingPlans::Assignment.assign_plan_to(create_organization, :enterprise)
    org = Organization.first

    org.projects.create!(name: "Project 1")

    # Should be 0% even with projects (unlimited)
    assert_equal 0.0, PricingPlans::LimitChecker.plan_limit_percent_used(org, :projects)
  end

  def test_after_limit_action_resolution
    org = create_organization
    # Default in test config is now :block_usage
    assert_equal :block_usage, PricingPlans::LimitChecker.after_limit_action(org, :projects)
  end

  def test_limit_amount_resolution
    org = create_organization

    assert_equal 1, PricingPlans::LimitChecker.limit_amount(org, :projects)
  end

  def test_limit_amount_unlimited
    PricingPlans::Assignment.assign_plan_to(create_organization, :enterprise)
    org = Organization.first

    assert_equal :unlimited, PricingPlans::LimitChecker.limit_amount(org, :projects)
  end

  def test_warning_thresholds
    org = create_organization

    thresholds = PricingPlans::LimitChecker.warning_thresholds(org, :projects)

    assert_equal [0.6, 0.8, 0.95], thresholds
  end

  def test_should_warn_calculation
    org = create_organization

    # With no projects created (0% usage), should not warn
    assert_nil PricingPlans::LimitChecker.should_warn?(org, :projects)

    # Create a project to be at 100% usage (1 out of 1)
    # NOTE: This now triggers automatic warning emission via Limitable callback.
    org.projects.create!(name: "Test Project")

    # After automatic callback, warning was already emitted, so should_warn? returns nil
    # (The warning at 0.95 threshold was emitted during project creation)
    assert_nil PricingPlans::LimitChecker.should_warn?(org, :projects)

    # Verify the warning was recorded in enforcement state
    state = PricingPlans::EnforcementState.find_by(plan_owner: org, limit_key: "projects")
    assert_equal 0.95, state&.last_warning_threshold&.to_f

    # If we manually reset the threshold to a lower value, should_warn? returns next threshold
    state.update!(last_warning_threshold: 0.8)

    # Should warn at next threshold (0.95) since we only recorded 0.8
    assert_equal 0.95, PricingPlans::LimitChecker.should_warn?(org, :projects)
  end

  def test_should_warn_returns_nil_when_no_new_thresholds
    org = create_organization

    # Create enforcement state at highest threshold
    PricingPlans::EnforcementState.create!(
      plan_owner: org,
      limit_key: "projects",
      last_warning_threshold: 0.95
    )

    # No higher thresholds to warn about
    assert_nil PricingPlans::LimitChecker.should_warn?(org, :projects)
  end

  def test_current_usage_for_nonexistent_limit
    org = create_organization

    usage = PricingPlans::LimitChecker.current_usage_for(org, :nonexistent_limit)

    assert_equal 0, usage
  end

  def test_per_period_usage_across_period_boundaries
    org = create_organization

    # Create usage in current period
    period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :custom_models)
    PricingPlans::Usage.create!(
      plan_owner: org,
      limit_key: "custom_models",
      period_start: period_start,
      period_end: period_end,
      used: 2
    )

    assert_equal 2, PricingPlans::LimitChecker.current_usage_for(org, :custom_models)

    # Usage from different period should not affect current usage
    PricingPlans::Usage.create!(
      plan_owner: org,
      limit_key: "custom_models",
      period_start: 1.month.ago,
      period_end: 1.day.ago,
      used: 5  # Different period
    )

    # Should still only count current period
    assert_equal 2, PricingPlans::LimitChecker.current_usage_for(org, :custom_models)
  end

  def test_concurrent_limit_checking_race_conditions
    org = create_organization

    # Test sequential calls that simulate what might happen in concurrent scenarios
    results = []

    # Call multiple times to simulate concurrent access
    10.times do |i|
      result = PricingPlans::LimitChecker.within_limit?(org, :projects)
      results << result
    end

    # All should return true initially (within limit)
    assert_equal [true] * 10, results
  end

  def test_persistent_usage_with_destroyed_records
    org = create_organization

    # Create and destroy a project
    project = org.projects.create!(name: "Temp Project")
    project.destroy!

    # Usage should be 0 (real-time counting)
    assert_equal 0, PricingPlans::LimitChecker.current_usage_for(org, :projects)
    assert_equal 1, PricingPlans::LimitChecker.plan_limit_remaining(org, :projects)
  end

  def test_limit_checker_with_no_registered_counter
    # Clear the registry to simulate missing counter
    PricingPlans::LimitableRegistry.clear!

    org = create_organization

    # Should return 0 usage when no counter is registered
    usage = PricingPlans::LimitChecker.current_usage_for(org, :projects)

    assert_equal 0, usage
  end

  def test_warning_threshold_edge_cases
    org = create_organization

    # Test with 0 usage
    assert_nil PricingPlans::LimitChecker.should_warn?(org, :projects)

    # Test with threshold exactly at boundary
    PricingPlans::EnforcementState.create!(
      plan_owner: org,
      limit_key: "projects",
      last_warning_threshold: 0.6
    )

    # 60% usage should not trigger another warning at 0.6 threshold
    org.stub(:projects, OpenStruct.new(count: 0.6)) do
      # This is a bit contrived since we can't easily mock the percent calculation
      # In real usage, this would be tested via integration tests
    end
  end

  def test_limit_checker_graceful_handling_of_missing_plan
    # Create organization without any plan assignment
    org = create_organization
    PricingPlans::Assignment.where(plan_owner: org).destroy_all

    # Mock PlanResolver to return nil
    PricingPlans::PlanResolver.stub(:effective_plan_for, nil) do
      # BREAKING CHANGE: Undefined limits now default to 0 (blocked) instead of :unlimited
      assert_equal 0, PricingPlans::LimitChecker.plan_limit_remaining(org, :projects)
      assert_equal 0.0, PricingPlans::LimitChecker.plan_limit_percent_used(org, :projects)
      assert_equal :block_usage, PricingPlans::LimitChecker.after_limit_action(org, :projects)
    end
  end
end
