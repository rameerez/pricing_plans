# frozen_string_literal: true

require "test_helper"

class BillingIntervalsTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
  end

  def configure_sprint_pricing
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
        stripe_price "price_concierge_month"
      end
    end
  end

  def pro
    PricingPlans::Registry.plan(:pro)
  end

  # Fails loudly on any Stripe access so tests can assert "no network at all".
  def without_stripe_calls
    calls = []
    stripe_mod = Module.new
    price_class = Class.new do
      define_singleton_method(:retrieve) do |id|
        calls << id
        raise StandardError, "Stripe must not be called"
      end
    end
    stripe_mod.const_set(:Price, price_class)
    Object.const_set(:Stripe, stripe_mod)
    yield

    assert_equal [], calls, "expected no Stripe::Price.retrieve calls"
  ensure
    Object.send(:remove_const, :Stripe) if defined?(Stripe)
  end

  # Stripe stub keyed by price id: { "price_x" => [cents, interval, interval_count] }
  def with_stripe_prices(prices)
    stripe_mod = Module.new
    recurring_struct = Struct.new(:interval, :interval_count)
    price_struct = Struct.new(:unit_amount, :recurring, :currency)
    price_class = Class.new do
      define_singleton_method(:retrieve) do |id|
        cents, interval, count = prices.fetch(id) { raise StandardError, "No such price: #{id}" }
        price_struct.new(cents, recurring_struct.new(interval, count || 1), "usd")
      end
    end
    stripe_mod.const_set(:Price, price_class)
    Object.const_set(:Stripe, stripe_mod)
    yield
  ensure
    Object.send(:remove_const, :Stripe) if defined?(Stripe)
  end

  # --- Declaring prices per interval ---

  def test_price_accepts_a_hash_of_interval_amounts
    configure_sprint_pricing

    assert_equal({ month: 24, quarter: 54, year: 108 }, pro.prices)
  end

  def test_price_getter_returns_the_monthly_amount
    configure_sprint_pricing

    assert_equal 24, pro.price
    assert_equal 2400, pro.price_cents
  end

  def test_numeric_price_is_shorthand_for_a_monthly_price
    plan = PricingPlans::Plan.new(:pro)
    plan.price 29

    assert_equal 29, plan.price
    assert_equal({ month: 29 }, plan.prices)
    assert_equal [:month], plan.billing_intervals
  end

  def test_prices_are_kept_in_canonical_interval_order
    plan = PricingPlans::Plan.new(:pro)
    plan.price year: 108, month: 24, week: 7, quarter: 54, day: 2

    assert_equal %i[day week month quarter year], plan.prices.keys
    assert_equal %i[day week month quarter year], plan.billing_intervals
  end

  def test_price_hash_accepts_string_keys
    plan = PricingPlans::Plan.new(:pro)
    plan.price "month" => 24, "year" => 108

    assert_equal({ month: 24, year: 108 }, plan.prices)
  end

  def test_prices_cannot_be_mutated_from_outside
    configure_sprint_pricing
    assert_raises(FrozenError) { pro.prices[:month] = 1 }
    assert_equal 24, pro.price
  end

  def test_prices_is_empty_without_a_numeric_price
    plan = PricingPlans::Plan.new(:enterprise)
    plan.price_string "Contact"

    assert_equal({}, plan.prices)
    assert_equal [], plan.billing_intervals
  end

  def test_set_price_nil_clears_the_price
    plan = PricingPlans::Plan.new(:pro)
    plan.price 24
    plan.set_price(nil)
    assert_nil plan.price
    assert_equal({}, plan.prices)
    refute plan.has_numeric_price?
  end

  def test_redeclaring_price_replaces_previous_intervals
    plan = PricingPlans::Plan.new(:pro)
    plan.price month: 24, year: 108
    plan.price 30

    assert_equal({ month: 30 }, plan.prices)
  end

  def test_unknown_price_interval_raises_a_clear_configuration_error
    plan = PricingPlans::Plan.new(:pro)
    error = assert_raises(PricingPlans::ConfigurationError) { plan.price month: 24, biweekly: 20 }
    assert_match(/Plan :pro/, error.message)
    assert_match(/:biweekly/, error.message)
    assert_match(/:day, :week, :month, :quarter, :year/, error.message)
  end

  def test_empty_price_hash_raises
    plan = PricingPlans::Plan.new(:pro)
    assert_raises(PricingPlans::ConfigurationError) { plan.price({}) }
  end

  def test_non_numeric_interval_amount_raises
    plan = PricingPlans::Plan.new(:pro)
    error = assert_raises(PricingPlans::ConfigurationError) { plan.price month: "24" }
    assert_match(/month/, error.message)
    assert_raises(PricingPlans::ConfigurationError) { plan.price month: nil }
  end

  def test_negative_or_non_finite_interval_amount_raises
    plan = PricingPlans::Plan.new(:pro)
    assert_raises(PricingPlans::ConfigurationError) { plan.price month: -1 }
    assert_raises(PricingPlans::ConfigurationError) { plan.price month: Float::INFINITY }
    assert_raises(PricingPlans::ConfigurationError) { plan.price month: Float::NAN }
  end

  def test_price_string_is_still_exclusive_with_a_price_hash
    plan = PricingPlans::Plan.new(:pro)
    plan.price month: 24
    plan.price_string "Contact"
    assert_raises(PricingPlans::ConfigurationError) { plan.validate! }
  end

  # --- stripe_price intervals ---

  def test_stripe_price_accepts_any_billing_interval
    plan = PricingPlans::Plan.new(:pro)
    plan.stripe_price day: "price_d", week: "price_w", month: "price_m", quarter: "price_q", year: "price_y"

    assert_equal "price_q", plan.price_id_for(:quarter)
    assert_equal "price_w", plan.price_id_for(:week)
    assert_equal "price_d", plan.price_id_for(:day)
    assert_equal %i[day week month quarter year], plan.billing_intervals
  end

  def test_stripe_price_keys_are_normalized_to_symbols
    plan = PricingPlans::Plan.new(:pro)
    plan.stripe_price "month" => "price_m", "quarter" => "price_q"

    assert_equal({ month: "price_m", quarter: "price_q" }, plan.stripe_price)
    assert_equal "price_q", plan.price_id_for(:quarter)
  end

  def test_unknown_stripe_price_key_raises_a_clear_configuration_error
    plan = PricingPlans::Plan.new(:pro)
    error = assert_raises(PricingPlans::ConfigurationError) { plan.stripe_price monthly: "price_m" }
    assert_match(/Plan :pro/, error.message)
    assert_match(/:monthly/, error.message)
    assert_match(/:id/, error.message)
  end

  def test_stripe_price_id_key_counts_as_monthly
    plan = PricingPlans::Plan.new(:pro)
    plan.stripe_price id: "price_m"

    assert_equal "price_m", plan.price_id_for(:month)
    assert_nil plan.price_id_for(:quarter)
    assert_equal [:month], plan.billing_intervals
  end

  def test_single_stripe_price_string_counts_as_monthly_interval
    plan = PricingPlans::Plan.new(:pro)
    plan.stripe_price "price_m"

    assert_equal [:month], plan.billing_intervals
    assert_equal "price_m", plan.price_id_for(:month)
  end

  def test_price_id_for_quarter_and_existing_accessors
    configure_sprint_pricing

    assert_equal "price_pro_quarter", pro.price_id_for(:quarter)
    assert_equal "price_pro_quarter", pro.price_id_for("quarter")
    assert_equal "price_pro_month", pro.monthly_price_id
    assert_equal "price_pro_year", pro.yearly_price_id
  end

  def test_price_id_for_rejects_unknown_intervals
    configure_sprint_pricing
    assert_raises(ArgumentError) { pro.price_id_for(:fortnight) }
  end

  def test_price_ids_lists_every_declared_stripe_id
    configure_sprint_pricing

    assert_equal %w[price_pro_month price_pro_quarter price_pro_year], pro.price_ids
    assert_equal ["price_concierge_month"], PricingPlans::Registry.plan(:concierge).price_ids
    assert_equal [], PricingPlans::Registry.plan(:free).price_ids
  end

  def test_billing_intervals_union_scalar_price_with_stripe_intervals
    plan = PricingPlans::Plan.new(:pro)
    plan.price 29
    plan.stripe_price month: "price_m", year: "price_y"
    plan.validate!

    assert_equal %i[month year], plan.billing_intervals
  end

  def test_price_hash_and_stripe_price_must_cover_the_same_intervals
    plan = PricingPlans::Plan.new(:pro)
    plan.price month: 24, year: 108
    plan.stripe_price month: "price_m", quarter: "price_q", year: "price_y"
    error = assert_raises(PricingPlans::ConfigurationError) { plan.validate! }
    assert_match(/Plan :pro/, error.message)
    assert_match(/quarter/, error.message)
  end

  def test_price_hash_intervals_without_a_stripe_id_raise
    plan = PricingPlans::Plan.new(:pro)
    plan.price month: 24, quarter: 54
    plan.stripe_price "price_m"
    error = assert_raises(PricingPlans::ConfigurationError) { plan.validate! }
    assert_match(/quarter/, error.message)
  end

  def test_price_hash_with_matching_stripe_id_key_is_valid
    plan = PricingPlans::Plan.new(:pro)
    plan.price month: 24
    plan.stripe_price id: "price_m"
    plan.validate!

    assert_equal [:month], plan.billing_intervals
  end

  def test_price_hash_without_stripe_price_is_valid
    plan = PricingPlans::Plan.new(:pro)
    plan.price month: 24, quarter: 54
    plan.validate!

    assert_equal %i[month quarter], plan.billing_intervals
  end

  def test_duplicate_quarter_price_ids_across_plans_are_rejected
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :a
        config.plan :a do
          stripe_price month: "price_a", quarter: "price_shared"
        end
        config.plan :b do
          stripe_price quarter: "price_shared"
        end
      end
    end
    assert_match(/price_shared/, error.message)
  end

  # --- price_components per interval ---

  def test_price_components_return_the_declared_quarter_amount
    configure_sprint_pricing
    without_stripe_calls do
      pc = pro.price_components(interval: :quarter)

      assert_equal true, pc.present?
      assert_equal :quarter, pc.interval
      assert_equal 5400, pc.amount_cents
      assert_equal "54", pc.amount
      assert_equal "$", pc.currency
      assert_equal "$54/qtr", pc.label
      assert_equal 1800, pc.monthly_equivalent_cents
      assert_equal "$18/mo", pc.monthly_equivalent_label
    end
  end

  def test_price_components_return_the_declared_year_amount_not_twelve_times_monthly
    configure_sprint_pricing
    without_stripe_calls do
      pc = pro.price_components(interval: :year)

      assert_equal 10_800, pc.amount_cents
      assert_equal "$108/yr", pc.label
      assert_equal 900, pc.monthly_equivalent_cents
      assert_equal "$9/mo", pc.monthly_equivalent_label
      assert_equal 10_800, pro.yearly_price_cents
    end
  end

  def test_price_components_for_the_declared_month
    configure_sprint_pricing
    pc = pro.price_components(interval: :month)

    assert_equal 2400, pc.amount_cents
    assert_equal "$24/mo", pc.label
    assert_equal 2400, pc.monthly_equivalent_cents
    assert_equal "$24/mo", pc.monthly_equivalent_label
  end

  def test_price_components_accept_string_intervals
    configure_sprint_pricing

    assert_equal 5400, pro.price_components(interval: "quarter").amount_cents
  end

  def test_price_components_reject_unknown_intervals
    configure_sprint_pricing
    error = assert_raises(ArgumentError) { pro.price_components(interval: :fortnight) }
    assert_match(/fortnight/, error.message)
  end

  def test_undeclared_interval_derives_from_the_monthly_price
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        price month: 24, year: 108
      end
    end
    pc = pro.price_components(interval: :quarter)

    assert_equal true, pc.present?
    assert_equal 7200, pc.amount_cents
    assert_equal "$72/qtr", pc.label
    assert_equal 2400, pc.monthly_equivalent_cents
  end

  def test_numeric_price_derives_every_interval_from_monthly
    plan = PricingPlans::Plan.new(:pro)
    plan.price 30

    assert_equal 9000, plan.price_components(interval: :quarter).amount_cents
    assert_equal 36_000, plan.price_components(interval: :year).amount_cents
    assert_equal 692, plan.price_components(interval: :week).amount_cents
    assert_equal "$6.92/wk", plan.price_components(interval: :week).label
    assert_equal 99, plan.price_components(interval: :day).amount_cents
  end

  def test_interval_without_monthly_price_to_derive_from_is_not_present
    plan = PricingPlans::Plan.new(:annual)
    plan.price year: 120
    pc = plan.price_components(interval: :month)

    refute_predicate pc, :present?
    assert_nil pc.amount_cents
    assert_nil pc.label
    assert_equal :month, pc.interval
    assert_nil plan.monthly_price_cents
    assert_equal 12_000, plan.yearly_price_cents
  end

  def test_fractional_amounts_render_with_cents
    plan = PricingPlans::Plan.new(:pro)
    plan.price month: 19.99, quarter: 49.5

    assert_equal "$19.99/mo", plan.price_label_for(:month)
    assert_equal "$49.50/qtr", plan.price_label_for(:quarter)
    assert_equal 1650, plan.price_components(interval: :quarter).monthly_equivalent_cents
    assert_equal "$16.50/mo", plan.price_components(interval: :quarter).monthly_equivalent_label
  end

  def test_week_and_day_monthly_equivalents
    plan = PricingPlans::Plan.new(:pass)
    plan.price week: 12, day: 3
    # 52 weeks / 12 months; 365 days / 12 months
    assert_equal 5200, plan.price_components(interval: :week).monthly_equivalent_cents
    assert_equal 9125, plan.price_components(interval: :day).monthly_equivalent_cents
    assert_equal "$12/wk", plan.price_label_for(:week)
    assert_equal "$3/day", plan.price_label_for(:day)
  end

  def test_price_components_resolver_receives_the_normalized_interval
    seen = []
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.price_components_resolver = lambda { |_plan, interval|
        seen << interval
        nil
      }
      config.plan :pro do
        price month: 24, quarter: 54
      end
    end
    pro.price_components(interval: "quarter")

    assert_equal [:quarter], seen
  end

  def test_price_components_respect_configured_currency
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.default_currency_symbol = "€"
      config.plan :pro do
        price month: 24, quarter: 54
      end
    end

    assert_equal "€54/qtr", pro.price_label_for(:quarter)
    assert_equal "€18/mo", pro.price_components(interval: :quarter).monthly_equivalent_label
  end

  # --- Stripe-derived components for new intervals ---

  def test_stripe_quarter_price_resolves_as_a_quarter
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        stripe_price month: "price_m", quarter: "price_q"
      end
    end
    with_stripe_prices("price_m" => [2400, "month"], "price_q" => [5400, "month", 3]) do
      pc = pro.price_components(interval: :quarter)

      assert_equal true, pc.present?
      assert_equal :quarter, pc.interval
      assert_equal 5400, pc.amount_cents
      assert_equal "$54/qtr", pc.label
      assert_equal 1800, pc.monthly_equivalent_cents
    end
  end

  def test_stripe_weekly_and_yearly_monthly_equivalents
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        stripe_price week: "price_w", year: "price_y"
      end
    end
    with_stripe_prices("price_w" => [1200, "week"], "price_y" => [10_800, "year"]) do
      assert_equal 5200, pro.price_components(interval: :week).monthly_equivalent_cents
      assert_equal "$12/wk", pro.price_label_for(:week)
      assert_equal 900, pro.price_components(interval: :year).monthly_equivalent_cents
    end
  end

  def test_stripe_labels_keep_cents_instead_of_rounding
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        stripe_price month: "price_m"
      end
    end

    with_stripe_prices("price_m" => [2999, "month"]) do
      assert_equal "$29.99/mo", pro.price_label_for(:month)
    end
  end

  def test_local_price_hash_wins_over_stripe_for_every_interval
    configure_sprint_pricing
    without_stripe_calls do
      assert_equal "$24/mo", pro.price_label
      assert_equal "$", pro.currency_symbol
      pro.billing_intervals.each { |interval| assert_predicate pro.price_components(interval: interval), :present? }
    end
  end

  # --- Labels, predicates, view models ---

  def test_price_label_for_a_year_only_plan_uses_its_declared_interval
    plan = PricingPlans::Plan.new(:annual)
    plan.price year: 120

    assert_equal "$120/yr", plan.price_label
  end

  def test_year_only_local_price_does_not_call_stripe_for_labels
    PricingPlans.configure do |config|
      config.default_plan = :annual
      config.plan :annual do
        price year: 120
        stripe_price year: "price_y"
      end
    end
    without_stripe_calls do
      plan = PricingPlans::Registry.plan(:annual)

      assert_equal "$120/yr", plan.price_label
      assert_equal "$", plan.currency_symbol
    end
  end

  def test_plan_price_label_for_year_only_plan
    PricingPlans.configure do |config|
      config.default_plan = :annual
      config.plan :annual do
        price year: 120
      end
    end

    assert_equal "$120/yr", PricingPlans.plan_price_label_for(PricingPlans::Registry.plan(:annual))
  end

  def test_free_and_purchasable_predicates_with_price_hash
    plan = PricingPlans::Plan.new(:pro)
    plan.price month: 24, year: 108

    refute_predicate plan, :free?
    assert_predicate plan, :purchasable?
    assert_predicate plan, :has_numeric_price?
    assert_predicate plan, :has_interval_prices?

    free = PricingPlans::Plan.new(:free)
    free.price month: 0

    assert_predicate free, :free?
    refute_predicate free, :purchasable?
  end

  def test_stripe_quarter_only_counts_as_interval_prices
    plan = PricingPlans::Plan.new(:pro)
    plan.stripe_price quarter: "price_q"

    assert_predicate plan, :has_interval_prices?
  end

  def test_monthly_equivalent_cents_is_the_cheapest_per_month_local_price
    configure_sprint_pricing

    assert_equal 2400, pro.monthly_equivalent_cents
    annual = PricingPlans::Plan.new(:annual)
    annual.price quarter: 60, year: 120

    assert_equal 1000, annual.monthly_equivalent_cents
    stripe_only = PricingPlans::Plan.new(:stripe_only)
    stripe_only.stripe_price "price_x"

    assert_nil stripe_only.monthly_equivalent_cents
  end

  def test_view_model_exposes_every_billing_interval
    configure_sprint_pricing
    without_stripe_calls do
      vm = pro.to_view_model

      assert_equal %i[month quarter year], vm[:billing_intervals]
      quarter = vm[:interval_prices][:quarter]

      assert_equal 5400, quarter[:amount_cents]
      assert_equal 1800, quarter[:monthly_equivalent_cents]
      assert_equal "$54/qtr", quarter[:label]
      assert_equal "$18/mo", quarter[:monthly_equivalent_label]
      assert_equal "price_pro_quarter", quarter[:price_id]
      assert_equal 2400, vm[:monthly_price_cents]
      assert_equal 10_800, vm[:yearly_price_cents]
    end
  end

  # --- Plan comparison stays monthly ---

  def test_comparison_uses_the_declared_monthly_price
    configure_sprint_pricing
    concierge = PricingPlans::Registry.plan(:concierge)
    free = PricingPlans::Registry.plan(:free)
    without_stripe_calls do
      assert pro.upgrade_from?(free)
      assert concierge.upgrade_from?(pro)
      assert pro.downgrade_from?(concierge)
      refute pro.upgrade_from?(concierge)
    end
  end

  def test_comparison_without_a_monthly_price_uses_the_cheapest_monthly_equivalent
    cheap = PricingPlans::Plan.new(:cheap)
    cheap.price month: 11
    annual = PricingPlans::Plan.new(:annual)
    annual.price quarter: 36, year: 120 # $12/mo and $10/mo

    assert cheap.upgrade_from?(annual)
    assert annual.downgrade_from?(cheap)
  end

  # --- CTA urls carry the interval ---

  def with_subscribe_path
    mod = Module.new do
      def self.subscribe_path(plan:, interval:)
        "/subscribe?plan=#{plan}&interval=#{interval}"
      end
    end
    Object.const_set(:Rails, Module.new)
    routes = OpenStruct.new(url_helpers: mod)
    Rails.define_singleton_method(:application) { OpenStruct.new(routes: routes) }
    yield
  ensure
    Object.send(:remove_const, :Rails) if defined?(Rails)
  end

  def test_cta_url_accepts_an_interval
    configure_sprint_pricing
    with_subscribe_path do
      assert_equal "/subscribe?plan=pro&interval=quarter", pro.cta_url(interval: :quarter)
      assert_equal "/subscribe?plan=pro&interval=month", pro.cta_url
    end
  end

  def test_cta_url_rejects_unknown_interval
    configure_sprint_pricing

    with_subscribe_path do
      assert_raises(ArgumentError) { pro.cta_url(interval: :fortnight) }
    end
  end

  def test_pricing_plan_cta_passes_the_interval_through
    configure_sprint_pricing
    with_subscribe_path do
      assert_equal "/subscribe?plan=pro&interval=quarter",
                   PricingPlans::ViewHelpers.pricing_plan_cta(pro, interval: :quarter)[:url]
      assert_equal "/subscribe?plan=pro&interval=month", PricingPlans::ViewHelpers.pricing_plan_cta(pro)[:url]
    end
  end
end
