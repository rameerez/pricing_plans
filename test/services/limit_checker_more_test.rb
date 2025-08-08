# frozen_string_literal: true

require "test_helper"

class LimitCheckerMoreTest < ActiveSupport::TestCase
  def setup
    super
    @org = create_organization
  end

  def test_remaining_returns_unlimited_when_no_limit_configured
    # For an unknown limit key, remaining should be :unlimited
    assert_equal :unlimited, PricingPlans::LimitChecker.remaining(@org, :unknown_limit)
    assert PricingPlans::LimitChecker.within_limit?(@org, :unknown_limit)
  end

  def test_after_limit_action_default_when_no_limit_configured
    # Default action when no limit is configured should be :block_usage per current implementation
    assert_equal :block_usage, PricingPlans::LimitChecker.after_limit_action(@org, :unknown_limit)
  end

  def test_percent_used_handles_unlimited_and_zero_limits
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      case key
      when :unlimited_key
        { to: :unlimited }
      when :zero_key
        { to: 0 }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      assert_equal 0.0, PricingPlans::LimitChecker.percent_used(@org, :unlimited_key)
      assert_equal 0.0, PricingPlans::LimitChecker.percent_used(@org, :zero_key)
    end
  end

  def test_should_warn_returns_highest_crossed_threshold_only_once
    org = @org
    # Prepare a plan with thresholds
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      { to: 10, warn_at: [0.5, 0.8] } if key == :projects
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      # Simulate usage at 9/10 = 90%
      PricingPlans::LimitChecker.stub(:current_usage_for, 9) do
        threshold = PricingPlans::LimitChecker.should_warn?(org, :projects)
        assert_equal 0.8, threshold
      end

      # Create an enforcement state with last_warning_threshold = 0.8
      state = PricingPlans::EnforcementState.create!(billable: org, limit_key: "projects", last_warning_threshold: 0.8)

      # Now at 6/10 = 60%, lower than last threshold → should be nil
      PricingPlans::LimitChecker.stub(:current_usage_for, 6) do
        assert_nil PricingPlans::LimitChecker.should_warn?(org, :projects)
      end

      # At 10/10 = 100%, higher than last threshold → still returns 0.8 (highest defined)
      PricingPlans::LimitChecker.stub(:current_usage_for, 10) do
        assert_nil PricingPlans::LimitChecker.should_warn?(org, :projects), "no new higher threshold to emit"
      end
    end
  end
end
