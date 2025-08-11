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

  def test_limit_returns_status_hash
    st = @org.limit(:projects)
    assert st.is_a?(Hash)
    assert_equal :projects, st[:limit_key]
    assert_equal true, st[:configured]
  end

  def test_limits_returns_hash_of_statuses
    sts = @org.limits(:projects, :custom_models)
    assert sts.is_a?(Hash)
    assert sts.key?(:projects)
    assert sts.key?(:custom_models)
  end

  def test_limits_defaults_to_all_configured
    sts = @org.limits
    assert sts.key?(:projects)
    assert sts.key?(:custom_models)
  end

  def test_limits_summary_returns_structs
    list = @org.limits_summary(:projects, :custom_models)
    assert list.is_a?(Array)
    item = list.first
    assert_respond_to item, :key
    assert_respond_to item, :current
    assert_respond_to item, :allowed
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
end
