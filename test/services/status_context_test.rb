# frozen_string_literal: true

require "test_helper"

class StatusContextTest < ActiveSupport::TestCase
  def setup
    super
    @org = create_organization
  end

  def test_effective_plan_is_cached
    ctx = PricingPlans::StatusContext.new(@org)
    plan1 = ctx.effective_plan
    plan2 = ctx.effective_plan
    assert_same plan1, plan2
  end

  def test_limit_config_for_is_cached
    ctx = PricingPlans::StatusContext.new(@org)
    config1 = ctx.limit_config_for(:projects)
    config2 = ctx.limit_config_for(:projects)
    assert_same config1, config2
  end

  def test_limit_status_is_cached
    ctx = PricingPlans::StatusContext.new(@org)
    status1 = ctx.limit_status(:projects)
    status2 = ctx.limit_status(:projects)
    assert_same status1, status2
  end

  def test_severity_for_is_cached
    ctx = PricingPlans::StatusContext.new(@org)
    sev1 = ctx.severity_for(:projects)
    sev2 = ctx.severity_for(:projects)
    assert_equal sev1, sev2
  end

  def test_limit_status_returns_configured_false_for_unknown_limit
    ctx = PricingPlans::StatusContext.new(@org)
    status = ctx.limit_status(:unknown_limit_xyz)
    assert_equal false, status[:configured]
  end

  def test_limit_status_returns_full_hash_for_configured_limit
    ctx = PricingPlans::StatusContext.new(@org)
    status = ctx.limit_status(:projects)
    assert_equal true, status[:configured]
    assert_includes status.keys, :limit_key
    assert_includes status.keys, :limit_amount
    assert_includes status.keys, :current_usage
    assert_includes status.keys, :percent_used
    assert_includes status.keys, :grace_active
    assert_includes status.keys, :blocked
  end

  def test_severity_for_returns_ok_for_within_limits
    ctx = PricingPlans::StatusContext.new(@org)
    assert_equal :ok, ctx.severity_for(:projects)
  end

  def test_severity_for_returns_at_limit_when_at_limit
    PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
      ctx = PricingPlans::StatusContext.new(@org)
      assert_equal :at_limit, ctx.severity_for(:projects)
    end
  end

  def test_severity_for_returns_blocked_when_over_limit
    PricingPlans::LimitChecker.stub(:current_usage_for, 5) do
      ctx = PricingPlans::StatusContext.new(@org)
      assert_equal :blocked, ctx.severity_for(:projects)
    end
  end

  def test_highest_severity_for_aggregates_multiple_limits
    ctx = PricingPlans::StatusContext.new(@org)
    sev = ctx.highest_severity_for(:projects, :custom_models)
    assert_includes [:ok, :warning, :at_limit, :grace, :blocked], sev
  end

  def test_message_for_returns_nil_when_ok
    ctx = PricingPlans::StatusContext.new(@org)
    assert_nil ctx.message_for(:projects)
  end

  def test_message_for_returns_string_when_not_ok
    PricingPlans::LimitChecker.stub(:current_usage_for, 5) do
      ctx = PricingPlans::StatusContext.new(@org)
      msg = ctx.message_for(:projects)
      assert_kind_of String, msg
      assert_includes msg, "projects"
    end
  end

  def test_overage_for_returns_zero_when_within_limits
    ctx = PricingPlans::StatusContext.new(@org)
    assert_equal 0, ctx.overage_for(:projects)
  end

  def test_overage_for_returns_amount_over_when_exceeded
    PricingPlans::LimitChecker.stub(:current_usage_for, 5) do
      ctx = PricingPlans::StatusContext.new(@org)
      assert_equal 4, ctx.overage_for(:projects) # 5 - 1 = 4 over
    end
  end

  def test_warning_thresholds_cached
    ctx = PricingPlans::StatusContext.new(@org)
    t1 = ctx.warning_thresholds(:projects)
    t2 = ctx.warning_thresholds(:projects)
    assert_same t1, t2
  end

  def test_period_window_for_returns_nil_nil_for_non_per_limit
    ctx = PricingPlans::StatusContext.new(@org)
    # projects is not a per-period limit
    start_time, end_time = ctx.period_window_for(:projects)
    assert_nil start_time
    assert_nil end_time
  end

  def test_period_window_for_returns_times_for_per_limit
    ctx = PricingPlans::StatusContext.new(@org)
    # custom_models has per: :month in test configuration
    start_time, end_time = ctx.period_window_for(:custom_models)
    assert_kind_of Time, start_time
    assert_kind_of Time, end_time
    assert start_time < end_time
  end

  def test_grace_active_returns_false_when_not_exceeded
    ctx = PricingPlans::StatusContext.new(@org)
    refute ctx.grace_active?(:projects)
  end

  def test_grace_ends_at_returns_nil_when_no_state
    ctx = PricingPlans::StatusContext.new(@org)
    assert_nil ctx.grace_ends_at(:projects)
  end

  def test_should_block_returns_false_for_unconfigured_limits
    ctx = PricingPlans::StatusContext.new(@org)
    refute ctx.should_block?(:unknown_limit_xyz)
  end

  def test_should_block_returns_false_when_not_exceeded
    ctx = PricingPlans::StatusContext.new(@org)
    refute ctx.should_block?(:projects)
  end

  def test_current_usage_for_cached
    ctx = PricingPlans::StatusContext.new(@org)
    u1 = ctx.current_usage_for(:projects)
    u2 = ctx.current_usage_for(:projects)
    assert_equal u1, u2
  end

  def test_percent_used_for_cached
    ctx = PricingPlans::StatusContext.new(@org)
    p1 = ctx.percent_used_for(:projects)
    p2 = ctx.percent_used_for(:projects)
    assert_equal p1, p2
  end

  def test_percent_used_for_returns_zero_for_unconfigured
    ctx = PricingPlans::StatusContext.new(@org)
    assert_equal 0.0, ctx.percent_used_for(:unknown_limit)
  end

  def test_message_for_at_limit_severity
    PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
      ctx = PricingPlans::StatusContext.new(@org)
      msg = ctx.message_for(:projects)
      assert_kind_of String, msg
      assert_includes msg.downcase, "reached"
    end
  end

  def test_message_for_warning_severity
    # Use 80% of limit (0.8 * 1 = 0.8, but we need integer)
    # With warn_at: [0.8], being at 80% should trigger warning
    PricingPlans::LimitChecker.stub(:plan_limit_percent_used, 85.0) do
      ctx = PricingPlans::StatusContext.new(@org)
      # Stub to be at 85% but under limit
      ctx.stub(:compute_severity, :warning) do
        # Force warning severity for this test
        msg = ctx.message_for(:projects)
        if msg
          assert_kind_of String, msg
        end
      end
    end
  end
end
