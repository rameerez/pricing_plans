# frozen_string_literal: true

require "test_helper"

class PlanResolutionTest < ActiveSupport::TestCase
  def test_plan_resolution_is_frozen
    resolution = PricingPlans::PlanResolution.new(
      plan: OpenStruct.new(key: :pro),
      source: :subscription,
      assignment: nil,
      subscription: OpenStruct.new(processor_plan: "price_pro_123")
    )

    assert resolution.frozen?
    assert_raises(FrozenError) { resolution.source = :default }
  end

  def test_plan_resolution_to_h_includes_struct_and_derived_fields
    assignment = OpenStruct.new(source: "admin")
    subscription = OpenStruct.new(processor_plan: "price_pro_123")

    resolution = PricingPlans::PlanResolution.new(
      plan: OpenStruct.new(key: :enterprise),
      source: :assignment,
      assignment: assignment,
      subscription: subscription
    )

    assert_equal(
      {
        plan: resolution.plan,
        source: :assignment,
        assignment: assignment,
        subscription: subscription,
        plan_key: :enterprise,
        assignment_source: "admin"
      },
      resolution.to_h
    )
  end
end
