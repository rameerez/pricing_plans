# frozen_string_literal: true

require "test_helper"

class UsageStatusHelpersTest < ActiveSupport::TestCase

  def setup
    super
    @org = create_organization
  end

  def test_status_returns_structs
    list = PricingPlans.status(@org, limits: [:projects, :custom_models, :activations])
    assert list.is_a?(Array)
    item = list.first
    assert_respond_to item, :key
    assert_respond_to item, :current
    assert_respond_to item, :allowed
    assert_respond_to item, :percent_used
  end

  def test_severity_and_message_and_overage_helpers
    org = @org
    assert_equal :ok, PricingPlans.severity_for(org, :projects)
    assert_nil PricingPlans.message_for(org, :projects)
    assert_equal 0, PricingPlans.overage_for(org, :projects)

    # Simulate over limit (allowed=1, current=2)
    PricingPlans::LimitChecker.stub(:current_usage_for, 2) do
      assert_includes [:warning, :grace, :blocked], PricingPlans.severity_for(org, :projects)
      assert_kind_of String, PricingPlans.message_for(org, :projects)
      assert_equal 1, PricingPlans.overage_for(org, :projects)
    end
  end

  def test_attention_and_approaching_helpers
    org = @org
    refute PricingPlans.attention_required?(org, :projects)
    refute PricingPlans.approaching_limit?(org, :projects)

    # at 100% of 1 allowed
    PricingPlans::LimitChecker.stub(:plan_limit_percent_used, 100.0) do
      assert PricingPlans.attention_required?(org, :projects)
      assert PricingPlans.approaching_limit?(org, :projects)
      assert PricingPlans.approaching_limit?(org, :projects, at: 0.5)
    end
  end

  def test_cta_for_with_defaults
    org = @org
    PricingPlans.configuration.default_cta_text = "Upgrade"
    PricingPlans.configuration.default_cta_url = "/billing"

    data = PricingPlans.cta_for(org)
    assert_equal({ text: "Upgrade", url: "/billing" }, data)
  ensure
    PricingPlans.configuration.default_cta_text = nil
    PricingPlans.configuration.default_cta_url = nil
  end

  def test_cta_for_fallback_to_redirect_on_blocked_limit
    org = @org
    # Ensure no defaults
    PricingPlans.configuration.default_cta_text = nil
    PricingPlans.configuration.default_cta_url = nil
    PricingPlans.configuration.redirect_on_blocked_limit = "/pricing"

    data = PricingPlans.cta_for(org)
    assert_equal "/pricing", data[:url]
  ensure
    PricingPlans.configuration.redirect_on_blocked_limit = nil
  end

  def test_alert_for_view_model
    org = @org
    vm = PricingPlans.alert_for(org, :projects)
    assert_equal false, vm[:visible?]

    PricingPlans::LimitChecker.stub(:current_usage_for, 2) do
      vm = PricingPlans.alert_for(org, :projects)
      assert_equal true, vm[:visible?]
      assert_includes [:warning, :grace, :blocked, :at_limit], vm[:severity]
      assert_kind_of String, vm[:title]
      assert_includes vm.keys, :cta_text
      assert_includes vm.keys, :cta_url
    end
  end
end
