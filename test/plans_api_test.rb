# frozen_string_literal: true

require "test_helper"

class PlansApiTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.plan :free do
        price 0
        metadata icon: "rocket", color: "bg-red-500"
        default!
      end
      config.plan :basic do
        price 10
      end
      config.plan :pro do
        price 20
        highlighted!
      end
      config.plan :enterprise do
        price_string "Contact"
      end
    end
  end

  def test_plans_returns_array_sorted
    keys = PricingPlans.plans.map(&:key)
    assert_equal [:free, :basic, :pro, :enterprise], keys
  end

  def test_plans_api_returns_sorted_plans
    array = PricingPlans.plans
    assert array.is_a?(Array)
    assert array.first.is_a?(PricingPlans::Plan)
  end

  def test_plans_exposes_metadata
    plan = PricingPlans.plans.find { |p| p.key == :free }

    assert_equal "rocket", plan.metadata[:icon]
    assert_equal "bg-red-500", plan.metadata[:color]
    assert_equal plan.meta, plan.metadata
  end

  def test_for_pricing_exposes_metadata
    plan = PricingPlans.for_pricing.find { |p| p[:key] == :free }

    assert_equal "rocket", plan[:metadata][:icon]
    assert_equal "bg-red-500", plan[:metadata][:color]
  end

  def test_view_models_expose_metadata
    plan = PricingPlans.view_models.find { |p| p[:key] == "free" }

    assert_equal "rocket", plan[:metadata][:icon]
    assert_equal "bg-red-500", plan[:metadata][:color]
  end

  def test_for_pricing_metadata_is_decoupled_from_plan
    plan = PricingPlans.plans.find { |p| p.key == :free }
    pricing = PricingPlans.for_pricing.find { |p| p[:key] == :free }

    pricing[:metadata][:icon] = "changed"
    assert_equal "rocket", plan.metadata[:icon]
  end

  def test_view_models_metadata_is_decoupled_from_plan
    plan = PricingPlans.plans.find { |p| p.key == :free }
    view_model = PricingPlans.view_models.find { |p| p[:key] == "free" }

    view_model[:metadata][:icon] = "changed"
    assert_equal "rocket", plan.metadata[:icon]
  end

  def test_suggest_next_plan_for_progression
    org = create_organization
    # free should satisfy zero usage
    assert_equal :free, PricingPlans.suggest_next_plan_for(org, keys: [:projects]).key
  end
end
