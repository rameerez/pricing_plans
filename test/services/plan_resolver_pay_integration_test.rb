# frozen_string_literal: true

require "test_helper"

class PlanResolverPayIntegrationTest < ActiveSupport::TestCase
  def setup
    super
    # Ensure pay is defined for these tests
    Object.const_set(:Pay, Module.new) unless defined?(Pay)
  end

  def test_maps_plan_when_stripe_price_is_string_and_subscription_processor_plan_matches
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price "price_pro_ABC"
      end
    end

    org = create_organization(pay_subscription: { active: true, processor_plan: "price_pro_ABC" })
    assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
  end

  def test_maps_plan_when_stripe_price_is_hash_with_id
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price({ id: "price_hash_ID", month: "price_month_X", year: "price_year_Y" })
      end
    end

    org = create_organization(pay_subscription: { active: true, processor_plan: "price_hash_ID" })
    assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
  end

  def test_maps_plan_when_stripe_price_is_hash_with_month
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price({ month: "price_month_only" })
      end
    end

    org = create_organization(pay_subscription: { active: true, processor_plan: "price_month_only" })
    assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
  end

  def test_maps_plan_when_stripe_price_is_hash_with_year
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price({ year: "price_year_only" })
      end
    end

    org = create_organization(pay_subscription: { active: true, processor_plan: "price_year_only" })
    assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
  end

  def test_maps_plan_when_multiple_plans_with_different_stripe_prices
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price "price_pro_111"
      end
      config.plan :premium do
        stripe_price({ month: "price_premium_month", year: "price_premium_year" })
      end
    end

    org = create_organization(pay_subscription: { active: true, processor_plan: "price_premium_month" })
    assert_equal :premium, PricingPlans::PlanResolver.effective_plan_for(org).key
  end

  def test_maps_plan_when_on_trial
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price "price_pro_trial"
      end
    end

    org = create_organization(pay_trial: true, pay_subscription: { processor_plan: "price_pro_trial" })
    assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
  end

  def test_maps_plan_when_on_grace_period
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price "price_pro_grace"
      end
    end

    org = create_organization(pay_grace_period: true, pay_subscription: { processor_plan: "price_pro_grace" })
    assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
  end

  def test_chooses_matching_subscription_from_collection
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price "price_pro_collection"
      end
    end

    org = create_organization
    # Provide multiple subscriptions; only one has the right processor_plan
    sub1 = OpenStruct.new(active?: false, on_trial?: false, on_grace_period?: false, processor_plan: "price_other")
    sub2 = OpenStruct.new(active?: true, on_trial?: false, on_grace_period?: false, processor_plan: "price_pro_collection")
    org.define_singleton_method(:subscriptions) { [sub1, sub2] }
    org.define_singleton_method(:subscription) { nil }

    assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
  end

  def test_falls_back_to_default_when_processor_plan_unknown
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price "price_known"
      end
    end

    org = create_organization(pay_subscription: { active: true, processor_plan: "price_unknown" })
    assert_equal :free, PricingPlans::PlanResolver.effective_plan_for(org).key
  end

  def test_no_pay_available_graceful_fallback
    org = create_organization
    PricingPlans::PlanResolver.stub(:pay_available?, false) do
      assert_equal :free, PricingPlans::PlanResolver.effective_plan_for(org).key
    end
  end
end
