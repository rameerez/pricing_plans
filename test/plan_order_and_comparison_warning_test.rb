# frozen_string_literal: true

require "test_helper"

class PlanOrderAndComparisonWarningTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
  end

  # --- Stable plan order ---

  STRIPE_ONLY_KEYS = (1..24).map { |n| :"stripe_plan_#{n}" }.freeze

  def configure_many_stripe_only_plans
    keys = STRIPE_ONLY_KEYS
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      keys.each_with_index do |key, index|
        config.plan key do
          stripe_price "price_#{index}"
        end
      end
      config.plan :basic do
        price 10
      end
    end
  end

  def test_plans_with_the_same_rank_keep_declaration_order
    configure_many_stripe_only_plans

    assert_equal [:free, :basic, *STRIPE_ONLY_KEYS], PricingPlans.plans.map(&:key)
  end

  def test_plan_order_is_identical_between_calls
    configure_many_stripe_only_plans
    first = PricingPlans.plans.map(&:key)

    5.times { assert_equal first, PricingPlans.plans.map(&:key) }
  end

  def test_equal_prices_keep_declaration_order
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :team_b do
        price 20
      end
      config.plan :team_a do
        price 20
      end
      config.plan :solo do
        price 5
      end
    end

    assert_equal %i[free solo team_b team_a], PricingPlans.plans.map(&:key)
  end

  def test_price_hash_plans_sort_by_their_monthly_price
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :concierge do
        price 99
      end
      config.plan :pro do
        price month: 24, quarter: 54, year: 108
      end
      config.plan :annual do
        price year: 120 # $10/mo equivalent
      end
      config.plan :free do
        price 0
      end
    end

    assert_equal %i[free annual pro concierge], PricingPlans.plans.map(&:key)
  end

  # --- Warning when a paid plan silently compares as $0 ---

  def configure_stripe_only_paid_plans
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price month: "price_pro_month"
      end
      config.plan :team do
        price 49
        stripe_price month: "price_team_month"
      end
    end
  end

  def test_warns_once_when_a_stripe_only_plan_compares_as_zero
    configure_stripe_only_paid_plans
    pro = PricingPlans::Registry.plan(:pro)
    free = PricingPlans::Registry.plan(:free)

    _out, err = capture_io do
      refute pro.upgrade_from?(free) # no Stripe: $0 vs $0
      refute pro.downgrade_from?(free)
      refute free.downgrade_from?(pro)
    end

    assert_equal 1, err.scan("[PricingPlans]").size, err
    assert_match(/:pro/, err)
    assert_match(/stripe_price/, err)
    assert_match(/price/, err)
  end

  def test_warning_names_each_offending_plan_once
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price month: "price_pro_month"
      end
      config.plan :max do
        stripe_price month: "price_max_month"
      end
    end
    pro = PricingPlans::Registry.plan(:pro)
    max = PricingPlans::Registry.plan(:max)

    _out, err = capture_io do
      max.upgrade_from?(pro)
      max.upgrade_from?(pro)
    end

    assert_equal 2, err.scan("[PricingPlans]").size, err
    assert_match(/:pro/, err)
    assert_match(/:max/, err)
  end

  def test_no_warning_when_the_plan_declares_a_local_price
    configure_stripe_only_paid_plans
    team = PricingPlans::Registry.plan(:team)
    free = PricingPlans::Registry.plan(:free)

    _out, err = capture_io { assert team.upgrade_from?(free) }

    assert_empty err
  end

  def test_no_warning_for_free_or_contact_plans
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :enterprise do
        price_string "Contact"
      end
    end
    free = PricingPlans::Registry.plan(:free)
    enterprise = PricingPlans::Registry.plan(:enterprise)

    _out, err = capture_io { enterprise.upgrade_from?(free) }

    assert_empty err
  end

  def test_no_warning_when_stripe_resolves_the_price
    configure_stripe_only_paid_plans
    stripe_mod = Module.new
    price_class = Class.new do
      def self.retrieve(_id)
        Struct.new(:unit_amount, :recurring, :currency).new(2900, Struct.new(:interval).new("month"), "usd")
      end
    end
    stripe_mod.const_set(:Price, price_class)
    Object.const_set(:Stripe, stripe_mod)

    pro = PricingPlans::Registry.plan(:pro)
    free = PricingPlans::Registry.plan(:free)
    _out, err = capture_io { assert pro.upgrade_from?(free) }

    assert_empty err
  ensure
    Object.send(:remove_const, :Stripe) if defined?(Stripe)
  end

  def test_warning_goes_to_the_rails_logger_when_available
    configure_stripe_only_paid_plans
    logger = Class.new do
      attr_reader :warnings

      def initialize = @warnings = []
      def warn(message) = @warnings << message
    end.new
    Object.const_set(:Rails, Module.new)
    Rails.define_singleton_method(:logger) { logger }

    pro = PricingPlans::Registry.plan(:pro)
    free = PricingPlans::Registry.plan(:free)
    _out, err = capture_io { pro.upgrade_from?(free) }

    assert_empty err
    assert_equal 1, logger.warnings.size
    assert_match(/:pro/, logger.warnings.first)
  ensure
    Object.send(:remove_const, :Rails) if defined?(Rails)
  end

  def test_comparison_result_is_unchanged_by_the_warning
    configure_stripe_only_paid_plans
    pro = PricingPlans::Registry.plan(:pro)
    team = PricingPlans::Registry.plan(:team)
    capture_io do
      assert team.upgrade_from?(pro)
      assert pro.downgrade_from?(team)
    end
  end
end
