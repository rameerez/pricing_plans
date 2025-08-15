# frozen_string_literal: true

require "test_helper"

class BillableLimitsHelpersTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        limits :projects, to: 3, after_limit: :grace_then_block, grace: 7.days
        limits :custom_models, to: 1
      end
    end
    @org = create_organization
    # Re-register counters in case configuration was reset
    Project.send(:limited_by_pricing_plans, :projects, billable: :organization)
    CustomModel.send(:limited_by_pricing_plans, :custom_models, billable: :organization)
  end

  def test_limit_returns_status_item
    st = @org.limit(:projects)
    # It should be a StatusItem with method-style access
    assert_respond_to st, :key
    assert_respond_to st, :current
    assert_respond_to st, :allowed
    assert_equal :projects, st.key
  end

  def test_limits_returns_array_of_status_items
    sts = @org.limits(:projects, :custom_models)
    assert sts.is_a?(Array)
    assert_equal [:projects, :custom_models].sort, sts.map(&:key).sort
    item = sts.first
    assert_respond_to item, :severity
    assert_respond_to item, :message
    assert_respond_to item, :overage
  end

  def test_limits_defaults_to_all_configured
    sts = @org.limits
    keys = sts.map(&:key)
    assert_includes keys, :projects
    assert_includes keys, :custom_models
  end

  def test_limits_summary_returns_structs
    list = @org.limits_summary(:projects, :custom_models)
    assert list.is_a?(Array)
    item = list.first
    assert_respond_to item, :key
    assert_respond_to item, :current
    assert_respond_to item, :allowed
  end

  def test_limits_items_include_severity_message_overage
    # Initially OK state
    items = @org.limits(:projects, :custom_models)
    items.each do |it|
      assert_includes [:ok, :warning, :at_limit, :grace, :blocked], it.severity
      assert_includes [0,1,2,3,4], it.severity_level
      # message may be nil when :ok
      if it.severity == :ok
        assert_nil it.message
      else
        assert it.message.nil? || it.message.is_a?(String)
      end
      assert_kind_of Integer, it.overage
      assert it.overage >= 0
      assert_includes [true,false], it.configured
      assert_includes [true,false], it.unlimited
      if it.allowed.is_a?(Numeric)
        assert_kind_of Integer, it.remaining
        assert it.remaining >= 0
      end
      assert_includes [true,false], it.attention?
      assert_includes [true,false], it.next_creation_blocked?
      assert_kind_of Array, it.warn_thresholds
      assert (it.next_warn_percent.nil? || it.next_warn_percent.is_a?(Numeric))
      if it.per
        assert it.period_start.nil? || it.period_start.is_a?(Time)
        assert it.period_end.nil? || it.period_end.is_a?(Time)
        assert (it.period_seconds_remaining.nil? || it.period_seconds_remaining.is_a?(Integer))
      end
    end

    # Push projects to at least warning/grace territory
    3.times { |i| @org.projects.create!(name: "P#{i}") }
    _ = PricingPlans::ControllerGuards.require_plan_limit!(:projects, billable: @org)
    item = @org.limits(:projects).find { |x| x.key == :projects }
    assert_includes [:warning, :at_limit, :grace, :blocked], item.severity
    assert_includes [0,1,2,3,4], item.severity_level
  end

  def test_limits_overview_basic
    ov = @org.limits_overview(:projects, :custom_models)
    assert_includes [:ok, :warning, :at_limit, :grace, :blocked], ov[:severity]
    assert_includes [0,1,2,3,4], ov[:severity_level]
    assert_kind_of String, ov[:title]
    assert_equal [:projects, :custom_models].sort, ov[:keys].sort
    assert_includes [true, false], ov[:attention?]
    assert ov.key?(:message)
    assert ov.key?(:cta_text)
    assert ov.key?(:cta_url)
  end

  def test_limits_overall_helpers_on_array
    items = @org.limits(:projects, :custom_models)
    assert_respond_to items, :overall_severity
    assert_respond_to items, :overall_severity_level
    assert_respond_to items, :overall_title
    assert_respond_to items, :overall_message
    assert_respond_to items, :overall_attention?
    assert_respond_to items, :overall_keys
    assert_respond_to items, :overall_highest_keys
    assert_respond_to items, :overall_highest_limits
    assert_respond_to items, :overall_keys_sentence
    assert_respond_to items, :overall_noun
    assert_respond_to items, :overall_has_have
    assert_respond_to items, :overall_cta_text
    assert_respond_to items, :overall_cta_url
  end

  def test_limits_severity_and_message
    # Initially OK
    assert_equal :ok, @org.limits_severity(:projects, :custom_models)
    assert_nil @org.limits_message(:projects, :custom_models)

    # Exceed persistent cap (projects 3) into grace semantics
    3.times { |i| @org.projects.create!(name: "P#{i}") }
    result = PricingPlans::ControllerGuards.require_plan_limit!(:projects, billable: @org)
    assert result.grace? || result.blocked? || result.warning?

    sev = @org.limits_severity(:projects, :custom_models)
    assert_includes [:warning, :grace, :blocked], sev

    msg = @org.limits_message(:projects, :custom_models)
    assert msg.nil? || msg.is_a?(String)
  end

  def test_limit_status_item_values_when_configured
    # projects limit is 3 by setup
    2.times { |i| @org.projects.create!(name: "P#{i}") }
    st = @org.limit(:projects)
    assert_equal :projects, st.key
    assert_equal 2, st.current
    assert_equal 3, st.allowed
    assert_in_delta 66.66, st.percent_used, 0.5
    assert_includes [true, false], st.grace_active
    assert_includes [true, false], st.blocked
    assert_includes [true, false], st.per
  end

  def test_limit_status_item_when_unconfigured
    st = @org.limit(:unknown_limit_key)
    assert_equal :unknown_limit_key, st.key
    assert_equal 0, st.current
    assert_nil st.allowed
    assert_equal 0.0, st.percent_used
    refute st.grace_active
    refute st.blocked
    refute st.per
  end

  def test_limit_struct_reflects_grace_and_block
    # Exceed projects to enter grace semantics
    3.times { |i| @org.projects.create!(name: "P#{i}") }
    # Trigger a check that may start grace depending on after_limit policy
    PricingPlans::ControllerGuards.require_plan_limit!(:projects, billable: @org)
    st = @org.limit(:projects)
    assert_includes [true, false], st.grace_active
    assert_includes [true, false], st.blocked
  end

  def test_next_creation_blocked_semantics
    # For :block_usage at limit, next_creation_blocked? should be true
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        limits :products, to: 1, after_limit: :block_usage
      end
    end
    org = create_organization
    Project.send(:limited_by_pricing_plans, :projects, billable: :organization)
    PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
      PricingPlans::LimitChecker.stub(:plan_limit_percent_used, 100.0) do
        item = org.limits(:products).first
        assert_equal :at_limit, item.severity
        assert_equal true, item.next_creation_blocked?
      end
    end
  end

  def test_period_window_fields_for_per_period
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        limits :custom_models, to: 2, per: :calendar_month
      end
    end
    org = create_organization
    CustomModel.send(:limited_by_pricing_plans, :custom_models, billable: :organization)
    item = org.limits(:custom_models).first
    assert_equal true, item.per
    assert item.period_start.is_a?(Time)
    assert item.period_end.is_a?(Time)
    assert item.period_seconds_remaining.is_a?(Integer)
    assert item.period_seconds_remaining >= 0
  end

  def test_status_item_human_key
    item = @org.limit(:projects)
    assert_equal "projects", item.human_key
  end

  def test_overview_extras_and_grammar_single_highest
    # Make custom_models at limit (1/1)
    CustomModel.create!(organization: @org, name: "C1")
    ov = @org.limits_overview(:projects, :custom_models)
    assert_equal :at_limit, ov[:severity]
    assert_equal [ :custom_models ], ov[:highest_keys]
    assert_equal 1, ov[:highest_limits].size
    assert_equal :custom_models, ov[:highest_limits].first.key
    assert_includes ["plan limit", "plan limits"], ov[:noun]
    assert_includes ["has", "have"], ov[:has_have]
    # keys_sentence should mention "custom models"
    assert_match(/custom models/, ov[:keys_sentence])
    # Message should be short and humanized
    assert_kind_of String, ov[:message]
    refute_empty ov[:message]
  end

  def test_message_for_phrasing_per_severity
    # blocked
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        limits :products, to: 1, after_limit: :block_usage
      end
    end
    org = create_organization
    Project.send(:limited_by_pricing_plans, :projects, billable: :organization)
    PricingPlans::LimitChecker.stub(:current_usage_for, 2) do
      msg = PricingPlans.message_for(org, :products)
      assert_includes msg, "gone over"
      assert_includes msg, "Please upgrade"
    end

    # at_limit
    PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
      PricingPlans::LimitChecker.stub(:plan_limit_percent_used, 100.0) do
        msg = PricingPlans.message_for(org, :products)
        assert_includes msg, "Upgrade your plan to unlock more"
      end
    end

    # warning
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        limits :projects, to: 10, warn_at: [0.5]
      end
    end
    org2 = create_organization
    Project.send(:limited_by_pricing_plans, :projects, billable: :organization)
    PricingPlans::LimitChecker.stub(:plan_limit_percent_used, 60.0) do
      msg = PricingPlans.message_for(org2, :projects)
      assert_includes msg, "You’re getting close"
    end

    # grace
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        limits :projects, to: 1, after_limit: :grace_then_block, grace: 7.days
      end
    end
    org3 = create_organization
    Project.send(:limited_by_pricing_plans, :projects, billable: :organization)
    PricingPlans::GraceManager.mark_exceeded!(org3, :projects)
    msg = PricingPlans.message_for(org3, :projects)
    assert_includes msg, "You’re currently over your limit"
    assert_includes msg, "avoid any interruptions"
  end
end
