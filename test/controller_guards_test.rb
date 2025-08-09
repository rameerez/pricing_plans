# frozen_string_literal: true

require "test_helper"

class ControllerGuardsTest < ActiveSupport::TestCase
  include PricingPlans::ControllerGuards

  def setup
    super
    @org = create_organization
  end

  def test_require_plan_limit_returns_within_when_no_limit_configured
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) { |_key| nil }

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      result = require_plan_limit!(:non_existent, billable: @org)
      assert result.within?
      assert_match(/no limit configured/i, result.message)
    end
  end

  def test_require_plan_limit_returns_within_when_unlimited
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      key == :projects ? { to: :unlimited } : nil
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      result = require_plan_limit!(:projects, billable: @org)
      assert result.within?
      assert_match(/unlimited/i, result.message)
    end
  end

  def test_require_plan_limit_within_limit_no_warning
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: 10, warn_at: [0.6, 0.8, 0.95], after_limit: :grace_then_block, grace: 7.days }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      result = require_plan_limit!(:projects, billable: @org)
      assert result.within?
      assert_match(/remaining/i, result.message)
    end
  end

  def test_require_plan_limit_exceeded_with_just_warn_policy
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: 1, after_limit: :just_warn }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
        result = require_plan_limit!(:projects, billable: @org, by: 1)
        assert result.warning?
        assert_match(/reached your limit/i, result.message)
        assert_match(/upgrade/i, result.message)
      end
    end
  end

  def test_require_plan_limit_exceeded_with_block_usage_policy
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: 1, after_limit: :block_usage }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
        result = require_plan_limit!(:projects, billable: @org, by: 1)
        assert result.blocked?
        assert_match(/reached your limit/i, result.message)
      end
    end
  end

  def test_require_plan_limit_exceeded_with_grace_then_block
    @org.projects.create!(name: "Project 1")
    result = require_plan_limit!(:projects, billable: @org, by: 1)
    assert result.grace?
    assert_match(/grace period/i, result.message)
  end

  def test_require_feature_allows_when_feature_enabled
    PricingPlans::Assignment.assign_plan_to(@org, :pro)
    assert_nothing_raised do
      require_feature!(:api_access, billable: @org)
    end
  end

  def test_require_feature_raises_when_feature_disabled
    error = assert_raises(PricingPlans::FeatureDenied) do
      require_feature!(:api_access, billable: @org)
    end
    assert_match(/your current plan/i, error.message)
    assert_equal :api_access, error.feature_key
    assert_equal @org, error.billable
  end
end
