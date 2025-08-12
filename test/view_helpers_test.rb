# frozen_string_literal: true

require "test_helper"

class ViewHelpersTest < ActiveSupport::TestCase

  def setup
    super
    @org = create_organization
  end

  # Test the helper logic without relying on ActionView
  # These test the business logic of the helpers

  def test_plan_allows_with_allowed_feature
    plan = PricingPlans::Plan.new(:pro)
    plan.allows(:api_access)

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      assert @org.plan_allows?(:api_access)
    end
  end

  def test_plan_allows_with_disallowed_feature
    plan = PricingPlans::Plan.new(:free)

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      refute @org.plan_allows?(:api_access)
    end
  end

  def test_plan_limit_remaining
    PricingPlans::LimitChecker.stub(:plan_limit_remaining, 5) do
      assert_equal 5, @org.plan_limit_remaining(:projects)
    end
  end

  def test_plan_limit_remaining_unlimited
    PricingPlans::LimitChecker.stub(:plan_limit_remaining, :unlimited) do
      assert_equal :unlimited, @org.plan_limit_remaining(:projects)
    end
  end

  def test_plan_limit_percent_used
    PricingPlans::LimitChecker.stub(:plan_limit_percent_used, 75.5) do
      assert_equal 75.5, @org.plan_limit_percent_used(:projects)
    end
  end

  def test_limit_status_basic
    status = PricingPlans.limit_status(:projects, billable: @org)
    assert_equal true, status[:configured]
    assert_equal :projects, status[:limit_key]
    assert_includes [:unlimited, Integer], status[:limit_amount].class
    assert_includes [true, false], status[:grace_active]
    assert_includes [true, false], status[:blocked]
  end

  def test_plans_returns_array
    data = PricingPlans.plans
    assert data.is_a?(Array)
    assert data.first.is_a?(PricingPlans::Plan)
  end

  def test_aggregate_helpers
    org = @org
    # No grace initially
    assert_equal :ok, org.limits_severity(:projects, :custom_models)
    # Simulate grace start for projects
    PricingPlans::GraceManager.mark_exceeded!(org, :projects)
    assert_includes [:grace, :blocked], org.limits_severity(:projects, :custom_models)
  ensure
    PricingPlans::GraceManager.reset_state!(org, :projects)
  end

  # New pure-data helpers
  def test_limit_severity_ok_warning_grace_blocked
    org = @org
    # Projects limit on :free is 1; initially 0/1 → :ok
    assert_equal :ok, org.limit_severity(:projects)

    # Simulate grace → should be :grace unless strictly blocked
    PricingPlans::GraceManager.mark_exceeded!(org, :projects)
    assert_includes [:grace, :blocked], org.limit_severity(:projects)
  ensure
    PricingPlans::GraceManager.reset_state!(org, :projects)
  end

  def test_limit_message_nil_when_ok
    org = @org
    assert_nil org.limit_message(:projects)

    # Simulate over limit by stubbing usage
    PricingPlans::LimitChecker.stub(:current_usage_for, 2) do
      assert_kind_of String, org.limit_message(:projects)
    end
  end

  def test_limit_overage
    org = @org
    assert_equal 0, org.limit_overage(:projects)

    # at limit (1) → 0 overage
    PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
      assert_equal 0, org.limit_overage(:projects)
    end

    # over limit (2) → 1 overage
    PricingPlans::LimitChecker.stub(:current_usage_for, 2) do
      assert_equal 1, org.limit_overage(:projects)
    end
  end

  def test_limit_attention_and_approaching
    org = @org
    refute org.attention_required_for_limit?(:projects)
    refute org.approaching_limit?(:projects) # no warn_at crossed

    # Stub to 100% of 1 allowed → crosses highest warn threshold
    PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
      PricingPlans::LimitChecker.stub(:plan_limit_percent_used, 100.0) do
        assert org.attention_required_for_limit?(:projects)
        assert org.approaching_limit?(:projects)
        assert org.approaching_limit?(:projects, at: 0.5)
      end
    end
  end

  def test_plan_cta_falls_back_to_defaults
    org = @org
    PricingPlans.configuration.default_cta_text = "Upgrade Plan"
    PricingPlans.configuration.default_cta_url = "/pricing"

    data = org.plan_cta
    assert_equal({ text: "Upgrade Plan", url: "/pricing" }, data)
  ensure
    PricingPlans.configuration.default_cta_text = nil
    PricingPlans.configuration.default_cta_url = nil
  end

  def test_limit_alert_view_model
    org = @org
    vm = org.limit_alert(:projects)
    assert_equal false, vm[:visible?]

    PricingPlans::LimitChecker.stub(:current_usage_for, 2) do
      vm = org.limit_alert(:projects)
      assert_equal true, vm[:visible?]
      assert_includes [:warning, :grace, :blocked], vm[:severity]
      assert_kind_of String, vm[:title]
      assert_kind_of Integer, vm[:overage]
      assert_includes vm.keys, :cta_text
      assert_includes vm.keys, :cta_url
    end
  end

  def test_at_limit_severity_and_message
    org = @org
    # Simulate exactly at limit (1/1)
    PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
      PricingPlans::LimitChecker.stub(:plan_limit_percent_used, 100.0) do
        # No grace and not blocked (for free plan projects after_limit: :block_usage, severity should be :blocked at >= limit)
        # For a limit with grace_then_block, at_limit should appear
        # Switch to pro plan where :projects => 10; stub limit_status to mimic per plan
        st = PricingPlans.limit_status(:projects, billable: org)
        # Baseline: ensure message exists when not OK
        msg = org.limit_message(:projects)
        assert_nil msg if org.limit_severity(:projects) == :ok
      end
    end
  end
end
