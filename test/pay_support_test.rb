# frozen_string_literal: true

require "test_helper"

class PaySupportTest < ActiveSupport::TestCase
  def test_subscription_active_for_handles_objects_without_id
    assert_equal false, PricingPlans::PaySupport.subscription_active_for?(Object.new)
  end

  def test_current_subscription_for_handles_objects_without_id
    assert_nil PricingPlans::PaySupport.current_subscription_for(Object.new)
  end
end
