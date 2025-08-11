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
end
