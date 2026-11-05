# frozen_string_literal: true

require "test_helper"

class PriceLookupTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        price month: 24, quarter: 54, year: 108
        stripe_price month: "price_pro_month", quarter: "price_pro_quarter", year: "price_pro_year"
      end
      config.plan :concierge do
        price 99
        stripe_price "price_concierge"
      end
      config.plan :legacy do
        stripe_price id: "price_legacy"
        hidden!
      end
    end
  end

  def test_plan_for_price_finds_the_plan_owning_a_price_id
    assert_equal :pro, PricingPlans.plan_for_price("price_pro_quarter").key
    assert_equal :pro, PricingPlans.plan_for_price("price_pro_year").key
    assert_equal :concierge, PricingPlans.plan_for_price("price_concierge").key
  end

  def test_plan_for_price_includes_hidden_plans
    assert_equal :legacy, PricingPlans.plan_for_price("price_legacy").key
  end

  def test_plan_for_price_returns_nil_for_unknown_or_blank_ids
    assert_nil PricingPlans.plan_for_price("price_nope")
    assert_nil PricingPlans.plan_for_price(nil)
    assert_nil PricingPlans.plan_for_price("")
  end

  def test_billing_interval_for_price
    assert_equal :quarter, PricingPlans.billing_interval_for("price_pro_quarter")
    assert_equal :month, PricingPlans.billing_interval_for("price_pro_month")
    assert_equal :year, PricingPlans.billing_interval_for("price_pro_year")
  end

  def test_single_id_and_id_key_count_as_monthly
    assert_equal :month, PricingPlans.billing_interval_for("price_concierge")
    assert_equal :month, PricingPlans.billing_interval_for("price_legacy")
  end

  def test_billing_interval_for_unknown_price_is_nil
    assert_nil PricingPlans.billing_interval_for("price_nope")
    assert_nil PricingPlans.billing_interval_for(nil)
  end

  def test_plan_billing_interval_for_only_answers_for_its_own_ids
    pro = PricingPlans::Registry.plan(:pro)

    assert_equal :quarter, pro.billing_interval_for("price_pro_quarter")
    assert_nil pro.billing_interval_for("price_concierge")
    assert_nil PricingPlans::Registry.plan(:free).billing_interval_for("price_pro_month")
  end

  def test_plan_resolver_uses_the_same_lookup
    assert_same PricingPlans.plan_for_price("price_pro_quarter"),
                PricingPlans::PlanResolver.plan_for_processor_plan("price_pro_quarter")
    assert_nil PricingPlans::PlanResolver.plan_for_processor_plan(nil)
  end

  def test_subscription_on_a_quarterly_price_resolves_to_the_plan
    org = create_organization
    subscription = OpenStruct.new(processor_plan: "price_pro_quarter", status: "active")
    PricingPlans::PlanResolver.stub(:pay_available?, true) do
      PricingPlans::PaySupport.stub(:current_subscriptions_for, [subscription]) do
        assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
      end
    end
  end
end
