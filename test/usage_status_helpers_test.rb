# frozen_string_literal: true

require "test_helper"

class UsageStatusHelpersTest < ActiveSupport::TestCase
  include PricingPlans::ViewHelpers

  def setup
    super
    @org = create_organization
  end

  def test_pricing_plans_status_returns_structs
    list = pricing_plans_status(@org, limits: [:projects, :custom_models, :activations])
    assert list.is_a?(Array)
    item = list.first
    assert_respond_to item, :key
    assert_respond_to item, :current
    assert_respond_to item, :allowed
    assert_respond_to item, :percent_used
  end
end
