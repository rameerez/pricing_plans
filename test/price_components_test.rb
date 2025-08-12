# frozen_string_literal: true

require "test_helper"

class PriceComponentsTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
  end

  def configure_with_numeric_price
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        price 29
      end
    end
  end

  def configure_with_price_string
    PricingPlans.configure do |config|
      config.default_plan = :enterprise
      config.plan :enterprise do
        price_string "Contact us"
      end
    end
  end

  def configure_with_stripe_ids
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        stripe_price month: "price_month_123", year: "price_year_456"
      end
    end
  end

  def with_stripe_stub(month_amount_cents: 2900, year_amount_cents: 29900, currency: "usd")
    stripe_mod = Module.new
    mmc = month_amount_cents
    ymc = year_amount_cents
    curr = currency
    price_class = Class.new do
      define_singleton_method(:retrieve) do |id|
        case id
        when "price_month_123"
          recurring = Struct.new(:interval).new("month")
          Struct.new(:unit_amount, :recurring, :currency).new(mmc, recurring, curr)
        when "price_year_456"
          recurring = Struct.new(:interval).new("year")
          Struct.new(:unit_amount, :recurring, :currency).new(ymc, recurring, curr)
        else
          recurring = Struct.new(:interval).new("month")
          Struct.new(:unit_amount, :recurring, :currency).new(mmc, recurring, curr)
        end
      end
    end
    stripe_mod.const_set(:Price, price_class)
    Object.const_set(:Stripe, stripe_mod)
    yield
  ensure
    Object.send(:remove_const, :Stripe) if defined?(Stripe)
  end

  def test_price_components_for_numeric_price_month
    configure_with_numeric_price
    plan = PricingPlans::Registry.plan(:pro)
    pc = plan.price_components(interval: :month)
    assert_equal true, pc.present?
    assert_equal "$", pc.currency
    assert_equal "29", pc.amount
    assert_equal 2900, pc.amount_cents
    assert_equal :month, pc.interval
    assert_match(/\$29\/mo/, pc.label)
    assert_equal 2900, pc.monthly_equivalent_cents
  end

  def test_price_components_for_numeric_price_year
    configure_with_numeric_price
    plan = PricingPlans::Registry.plan(:pro)
    pc = plan.price_components(interval: :year)
    assert_equal true, pc.present?
    assert_equal :year, pc.interval
    assert_match(/\/yr\z/, pc.label)
  end

  def test_price_components_for_price_string
    configure_with_price_string
    plan = PricingPlans::Registry.plan(:enterprise)
    pc = plan.price_components(interval: :month)
    refute pc.present?
    assert_equal "Contact us", pc.label
    assert_nil pc.amount
    assert_nil pc.amount_cents
  end

  def test_price_components_from_stripe
    configure_with_stripe_ids
    plan = PricingPlans::Registry.plan(:pro)
    with_stripe_stub do
      pcm = plan.monthly_price_components
      pcy = plan.yearly_price_components
      assert_equal 2900, pcm.amount_cents
      assert_equal 29900, pcy.amount_cents
      assert_equal "$", plan.currency_symbol
    end
  end

  def test_currency_symbol_mapping_eur
    configure_with_stripe_ids
    plan = PricingPlans::Registry.plan(:pro)
    with_stripe_stub(month_amount_cents: 1000, year_amount_cents: 12000, currency: "eur") do
      assert_equal "€", plan.currency_symbol
    end
  end

  class MemoryCache
    attr_reader :writes
    def initialize
      @store = {}
      @writes = []
    end
    def read(key)
      @store[key]
    end
    def write(key, value, **_opts)
      @writes << key
      @store[key] = value
    end
  end

  def test_stripe_lookup_uses_cache_when_available
    cache = MemoryCache.new
    configure_with_stripe_ids
    PricingPlans.configuration.price_cache = cache
    plan = PricingPlans::Registry.plan(:pro)
    with_stripe_stub do
      plan.monthly_price_components
      assert cache.writes.any?
    end
  ensure
    PricingPlans.configuration.price_cache = nil
  end
end


