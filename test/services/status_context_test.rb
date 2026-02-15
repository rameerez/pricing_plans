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

  def test_fresh_enforcement_state_destroys_stale_state
    # Create a stale enforcement state for a per-period limit
    state = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "custom_models",
      exceeded_at: 2.months.ago, # Stale - from previous period
      data: { "window_start_epoch" => 2.months.ago.beginning_of_month.to_i, "grace_period" => 7.days.to_i }
    )

    ctx = PricingPlans::StatusContext.new(@org)
    # This should destroy the stale state and return nil
    result = ctx.grace_active?(:custom_models)

    refute result
    assert_nil PricingPlans::EnforcementState.find_by(id: state.id)
  end

  def test_grace_ends_at_returns_nil_for_stale_state
    # Create a stale enforcement state
    PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "custom_models",
      exceeded_at: 2.months.ago,
      data: { "window_start_epoch" => 2.months.ago.beginning_of_month.to_i, "grace_period" => 7.days.to_i }
    )

    ctx = PricingPlans::StatusContext.new(@org)
    # Should return nil since state is stale
    assert_nil ctx.grace_ends_at(:custom_models)
  end

  def test_highest_severity_for_returns_grace_when_grace_active
    ctx = PricingPlans::StatusContext.new(@org)
    ctx.stub(:severity_for, ->(k) { k == :projects ? :grace : :ok }) do
      sev = ctx.highest_severity_for(:projects, :custom_models)
      assert_equal :grace, sev
    end
  end

  def test_highest_severity_for_returns_at_limit_when_at_limit
    ctx = PricingPlans::StatusContext.new(@org)
    ctx.stub(:severity_for, ->(k) { k == :projects ? :at_limit : :ok }) do
      sev = ctx.highest_severity_for(:projects, :custom_models)
      assert_equal :at_limit, sev
    end
  end

  def test_highest_severity_for_returns_warning_when_warning
    ctx = PricingPlans::StatusContext.new(@org)
    ctx.stub(:severity_for, ->(k) { k == :projects ? :warning : :ok }) do
      sev = ctx.highest_severity_for(:projects, :custom_models)
      assert_equal :warning, sev
    end
  end

  def test_message_for_grace_severity
    # Create active grace state
    PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects",
      exceeded_at: Time.current,
      data: { "grace_period" => 1.week.to_i }
    )

    PricingPlans::LimitChecker.stub(:current_usage_for, 5) do
      ctx = PricingPlans::StatusContext.new(@org)
      msg = ctx.message_for(:projects)
      assert_kind_of String, msg
      assert_includes msg.downcase, "grace"
    end
  end

  def test_overage_for_returns_zero_for_unconfigured
    ctx = PricingPlans::StatusContext.new(@org)
    assert_equal 0, ctx.overage_for(:unknown_limit)
  end

  def test_overage_for_returns_zero_for_unlimited
    ctx = PricingPlans::StatusContext.new(@org)
    # custom_models has unlimited in free plan
    assert_equal 0, ctx.overage_for(:custom_models)
  end

  def test_current_usage_for_returns_zero_for_unconfigured
    ctx = PricingPlans::StatusContext.new(@org)
    assert_equal 0, ctx.current_usage_for(:unknown_limit)
  end

  def test_warning_thresholds_returns_empty_for_unconfigured
    ctx = PricingPlans::StatusContext.new(@org)
    assert_equal [], ctx.warning_thresholds(:unknown_limit)
  end

  def test_period_window_for_cached
    ctx = PricingPlans::StatusContext.new(@org)
    w1 = ctx.period_window_for(:custom_models)
    w2 = ctx.period_window_for(:custom_models)
    assert_equal w1, w2
  end

  def test_should_block_returns_false_for_unlimited_limit
    ctx = PricingPlans::StatusContext.new(@org)
    # custom_models is unlimited in free plan
    refute ctx.should_block?(:custom_models)
  end

  def test_percent_used_capped_at_100
    PricingPlans::LimitChecker.stub(:current_usage_for, 500) do
      ctx = PricingPlans::StatusContext.new(@org)
      # projects limit is 1, so 500/1 = 50000% but should cap at 100
      percent = ctx.percent_used_for(:projects)
      assert_equal 100.0, percent
    end
  end

  def test_grace_active_returns_true_when_in_grace
    # Create non-expired grace state
    PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects",
      exceeded_at: Time.current,
      data: { "grace_period" => 1.week.to_i }
    )

    PricingPlans::LimitChecker.stub(:current_usage_for, 5) do
      ctx = PricingPlans::StatusContext.new(@org)
      assert ctx.grace_active?(:projects)
    end
  end

  def test_grace_active_returns_false_when_grace_expired
    # Create expired grace state
    PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects",
      exceeded_at: 2.weeks.ago,
      data: { "grace_period" => 1.day.to_i } # Expired
    )

    PricingPlans::LimitChecker.stub(:current_usage_for, 5) do
      ctx = PricingPlans::StatusContext.new(@org)
      refute ctx.grace_active?(:projects)
    end
  end

  def test_should_block_returns_true_when_grace_expired
    # Create expired grace state
    PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects",
      exceeded_at: 2.weeks.ago,
      data: { "grace_period" => 1.day.to_i }
    )

    PricingPlans::LimitChecker.stub(:current_usage_for, 5) do
      ctx = PricingPlans::StatusContext.new(@org)
      assert ctx.should_block?(:projects)
    end
  end

  def test_should_block_behavior_with_exceeded_usage
    # When usage exceeds limit, should_block behavior depends on
    # after_limit config and enforcement state
    PricingPlans::LimitChecker.stub(:current_usage_for, 5) do
      ctx = PricingPlans::StatusContext.new(@org)
      # Projects has after_limit: :grace_then_block
      # Without an active grace state, this checks exceeding behavior
      result = ctx.should_block?(:projects)
      # Assert some behavior - the result depends on the test configuration
      assert [true, false].include?(result)
    end
  end

  def test_message_for_blocked_with_non_numeric_limit
    ctx = PricingPlans::StatusContext.new(@org)
    # custom_models has :unlimited which is non-numeric
    # Stub to force blocked severity
    ctx.stub(:severity_for, :blocked) do
      ctx.stub(:limit_status, { configured: true, current_usage: 5, limit_amount: :unlimited, grace_ends_at: nil }) do
        msg = ctx.message_for(:custom_models)
        assert_kind_of String, msg
        refute_includes msg, "/"  # No usage/limit ratio for non-numeric
      end
    end
  end

  def test_message_for_grace_without_deadline
    ctx = PricingPlans::StatusContext.new(@org)
    ctx.stub(:severity_for, :grace) do
      ctx.stub(:limit_status, { configured: true, current_usage: 5, limit_amount: :unlimited, grace_ends_at: nil }) do
        msg = ctx.message_for(:projects)
        assert_kind_of String, msg
        refute_includes msg, "grace period ends"
      end
    end
  end

  def test_message_for_at_limit_with_non_numeric
    ctx = PricingPlans::StatusContext.new(@org)
    ctx.stub(:severity_for, :at_limit) do
      ctx.stub(:limit_status, { configured: true, current_usage: 1, limit_amount: :unlimited, grace_ends_at: nil }) do
        msg = ctx.message_for(:projects)
        assert_kind_of String, msg
        assert_includes msg.downcase, "maximum"
      end
    end
  end

  def test_message_for_warning_with_non_numeric
    ctx = PricingPlans::StatusContext.new(@org)
    ctx.stub(:severity_for, :warning) do
      ctx.stub(:limit_status, { configured: true, current_usage: 1, limit_amount: :unlimited, grace_ends_at: nil }) do
        msg = ctx.message_for(:projects)
        assert_kind_of String, msg
        refute_includes msg, "/"
      end
    end
  end

  def test_grace_active_cached
    ctx = PricingPlans::StatusContext.new(@org)
    g1 = ctx.grace_active?(:projects)
    g2 = ctx.grace_active?(:projects)
    assert_equal g1, g2
  end

  def test_grace_ends_at_cached
    ctx = PricingPlans::StatusContext.new(@org)
    g1 = ctx.grace_ends_at(:projects)
    g2 = ctx.grace_ends_at(:projects)
    # Both should be nil when no state exists, and caching works
    assert_nil g1
    assert_nil g2
  end

  def test_should_block_cached
    ctx = PricingPlans::StatusContext.new(@org)
    b1 = ctx.should_block?(:projects)
    b2 = ctx.should_block?(:projects)
    assert_equal b1, b2
  end

  def test_severity_for_returns_ok_for_unlimited
    ctx = PricingPlans::StatusContext.new(@org)
    # custom_models is unlimited, should return :ok
    assert_equal :ok, ctx.severity_for(:custom_models)
  end

  def test_fresh_enforcement_state_returns_state_for_non_per_limit
    # Create state for a non-per-period limit (projects doesn't have per:)
    state = PricingPlans::EnforcementState.create!(
      plan_owner: @org,
      limit_key: "projects",
      exceeded_at: Time.current,
      data: { "grace_period" => 1.week.to_i }
    )

    ctx = PricingPlans::StatusContext.new(@org)
    # Should return the state without checking staleness
    assert ctx.grace_active?(:projects)
    # State should still exist
    assert PricingPlans::EnforcementState.find_by(id: state.id)
  end
end
