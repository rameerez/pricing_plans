# frozen_string_literal: true

require "test_helper"

class PlanPricingApiTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
  end

  def with_stripe_stub(month_amount_cents: 1500, year_amount_cents: 18000, currency: "usd", month_id: "price_m", year_id: "price_y")
    stripe_mod = Module.new
    mmc = month_amount_cents
    ymc = year_amount_cents
    curr = currency
    mid = month_id
    yid = year_id
    price_class = Class.new do
      define_singleton_method(:retrieve) do |id|
        if id == mid
          recurring = Struct.new(:interval).new("month")
          Struct.new(:unit_amount, :recurring, :currency).new(mmc, recurring, curr)
        else
          recurring = Struct.new(:interval).new("year")
          Struct.new(:unit_amount, :recurring, :currency).new(ymc, recurring, curr)
        end
      end
    end
    stripe_mod.const_set(:Price, price_class)
    Object.const_set(:Stripe, stripe_mod)
    yield
  ensure
    Object.send(:remove_const, :Stripe) if defined?(Stripe)
  end

  def test_has_interval_prices_with_numeric_and_string
    PricingPlans.configure do |config|
      config.default_plan = :basic
      config.plan :basic do
        price 10
      end
    end
    plan = PricingPlans::Registry.plan(:basic)
    assert plan.has_interval_prices?
    assert plan.has_numeric_price?

    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :ent
      config.plan :ent do
        price_string "Contact"
      end
    end
    plan2 = PricingPlans::Registry.plan(:ent)
    assert plan2.has_interval_prices?
    refute plan2.has_numeric_price?
  end

  def test_has_interval_prices_with_stripe_month_year
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        stripe_price month: "price_m", year: "price_y"
      end
    end
    assert PricingPlans::Registry.plan(:pro).has_interval_prices?
  end

  def test_label_for_month_and_year_from_stripe
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        stripe_price month: "price_m", year: "price_y"
      end
    end
    plan = PricingPlans::Registry.plan(:pro)
    with_stripe_stub(month_amount_cents: 1500, year_amount_cents: 18000) do
      assert_match(/\$15\/mo/, plan.price_label_for(:month))
      assert_match(/\$180\/yr/, plan.price_label_for(:year))
    end
  end

  def test_monthly_and_yearly_price_cents_and_ids
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        stripe_price month: "price_m", year: "price_y"
      end
    end
    plan = PricingPlans::Registry.plan(:pro)
    with_stripe_stub(month_amount_cents: 990, year_amount_cents: 9990) do
      assert_equal 990, plan.monthly_price_cents
      assert_equal 9990, plan.yearly_price_cents
      assert_equal "price_m", plan.monthly_price_id
      assert_equal "price_y", plan.yearly_price_id
    end
  end

  def test_to_view_model_contains_expected_keys
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
        limits :projects, to: 3
      end
    end
    vm = PricingPlans::Registry.plan(:free).to_view_model
    assert_equal %i[id key name description features highlighted default free currency monthly_price_cents yearly_price_cents monthly_price_id yearly_price_id price_label price_string limits].sort, vm.keys.sort
  end

  def test_plan_comparison_and_downgrade_policy
    PricingPlans.configure do |config|
      config.default_plan = :basic
      config.plan :basic do
        price 10
      end
      config.plan :pro do
        price 20
      end
      config.downgrade_policy = ->(from:, to:, plan_owner:) { to.price.to_i < from.price.to_i ? [false, "Not allowed"] : [true, nil] }
    end
    basic = PricingPlans::Registry.plan(:basic)
    pro = PricingPlans::Registry.plan(:pro)
    assert pro.upgrade_from?(basic)
    assert basic.downgrade_from?(pro)
    assert_equal "Not allowed", basic.downgrade_blocked_reason(from: pro)
  end
end
