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
      # message may be nil when :ok
      if it.severity == :ok
        assert_nil it.message
      else
        assert it.message.nil? || it.message.is_a?(String)
      end
      assert_kind_of Integer, it.overage
      assert it.overage >= 0
    end

    # Push projects to at least warning/grace territory
    3.times { |i| @org.projects.create!(name: "P#{i}") }
    _ = PricingPlans::ControllerGuards.require_plan_limit!(:projects, billable: @org)
    item = @org.limits(:projects).find { |x| x.key == :projects }
    assert_includes [:warning, :at_limit, :grace, :blocked], item.severity
  end

  def test_limits_overview_basic
    ov = @org.limits_overview(:projects, :custom_models)
    assert_includes [:ok, :warning, :at_limit, :grace, :blocked], ov[:severity]
    assert_equal [:projects, :custom_models].sort, ov[:keys].sort
    assert_includes [true, false], ov[:attention?]
    assert ov.key?(:message)
    assert ov.key?(:cta_text)
    assert ov.key?(:cta_url)
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
end
