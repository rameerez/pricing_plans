# frozen_string_literal: true

require "test_helper"

class PlansApiTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.plan :free do
        price 0
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

  def test_for_dashboard_returns_struct
    org = create_organization
    data = PricingPlans.for_dashboard(org)
    assert_equal [:plans, :popular_plan_key, :current_plan].sort, data.to_h.keys.sort
    assert data.plans.is_a?(Array)
  end

  def test_for_marketing_returns_struct_without_current
    data = PricingPlans.for_marketing
    assert data.plans.is_a?(Array)
    assert_nil data.current_plan
  end

  def test_suggest_next_plan_for_progression
    org = create_organization
    # free should satisfy zero usage
    assert_equal :free, PricingPlans.suggest_next_plan_for(org, keys: [:projects]).key
  end
end
