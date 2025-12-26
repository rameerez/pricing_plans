# frozen_string_literal: true

require "test_helper"

class HiddenPlansTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
  end

  # ========================================
  # PLAN-LEVEL TESTS
  # ========================================

  def test_plan_can_be_marked_hidden
    plan = PricingPlans::Plan.new(:test)
    refute plan.hidden?, "Plan should not be hidden by default"

    plan.hidden!
    assert plan.hidden?, "Plan should be hidden after calling hidden!"
  end

  def test_plan_hidden_with_false_argument
    plan = PricingPlans::Plan.new(:test)
    plan.hidden!(false)
    refute plan.hidden?, "Plan should not be hidden when hidden!(false) is called"
  end

  def test_plan_hidden_predicate_returns_boolean
    plan = PricingPlans::Plan.new(:test)
    assert_equal false, plan.hidden?

    plan.hidden!
    assert_equal true, plan.hidden?
  end

  # ========================================
  # PUBLIC API FILTERING TESTS
  # ========================================

  def test_hidden_plans_filtered_from_public_plans_api
    PricingPlans.configure do |config|
      config.plan :unsubscribed do
        price 0
        hidden!
        default!
      end

      config.plan :starter do
        price 10
      end

      config.plan :pro do
        price 20
      end

      config.plan :legacy do
        price 15
        hidden!  # Grandfathered plan
      end
    end

    visible_plans = PricingPlans.plans
    assert_equal 2, visible_plans.size, "Should only return visible plans"
    assert_equal [:starter, :pro], visible_plans.map(&:key), "Should only include starter and pro (sorted by price: 10, 20)"
  end

  def test_hidden_plans_filtered_from_for_pricing
    PricingPlans.configure do |config|
      config.plan :unsubscribed do
        price 0
        hidden!
        default!
      end

      config.plan :starter do
        price 10
      end
    end

    pricing_data = PricingPlans.for_pricing
    assert_equal 1, pricing_data.size, "Should only return visible plans"
    assert_equal :starter, pricing_data.first[:key]
  end

  def test_hidden_plans_filtered_from_view_models
    PricingPlans.configure do |config|
      config.plan :unsubscribed do
        price 0
        hidden!
        default!
      end

      config.plan :starter do
        price 10
      end
    end

    view_models = PricingPlans.view_models
    assert_equal 1, view_models.size, "Should only return visible plans"
    assert_equal "starter", view_models.first[:key]
  end

  # ========================================
  # INTERNAL API TESTS (must NOT filter)
  # ========================================

  def test_registry_plans_includes_hidden_plans
    PricingPlans.configure do |config|
      config.plan :unsubscribed do
        price 0
        hidden!
        default!
      end

      config.plan :starter do
        price 10
      end
    end

    all_plans = PricingPlans::Registry.plans
    assert_equal 2, all_plans.size, "Registry should include all plans including hidden"
    assert all_plans.key?(:unsubscribed), "Registry should include hidden :unsubscribed plan"
    assert all_plans.key?(:starter), "Registry should include visible :starter plan"
  end

  def test_registry_can_lookup_hidden_plan_by_key
    PricingPlans.configure do |config|
      config.plan :unsubscribed do
        price 0
        hidden!
        default!
      end

      config.plan :starter do
        price 10
      end
    end

    unsubscribed_plan = PricingPlans::Registry.plan(:unsubscribed)
    assert_equal :unsubscribed, unsubscribed_plan.key
    assert unsubscribed_plan.hidden?
  end

  def test_registry_default_plan_can_be_hidden
    PricingPlans.configure do |config|
      config.plan :unsubscribed do
        price 0
        hidden!
        default!
      end

      config.plan :starter do
        price 10
      end
    end

    default_plan = PricingPlans::Registry.default_plan
    assert_equal :unsubscribed, default_plan.key
    assert default_plan.hidden?, "Default plan can be hidden"
  end

  # ========================================
  # VALIDATION TESTS
  # ========================================

  def test_validation_error_when_highlighted_plan_is_hidden
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.plan :unsubscribed do
          price 0
          hidden!
          default!
        end

        config.plan :starter do
          price 10
          hidden!
          highlighted!  # ERROR: can't be both hidden and highlighted
        end
      end
    end

    assert_match(/highlighted_plan starter cannot be hidden/, error.message)
  end

  def test_validation_passes_when_default_plan_is_hidden_but_highlighted_is_not
    # Should not raise error
    PricingPlans.configure do |config|
      config.plan :unsubscribed do
        price 0
        hidden!
        default!
      end

      config.plan :starter do
        price 10
        highlighted!  # OK: highlighted but NOT hidden
      end
    end

    assert_equal :unsubscribed, PricingPlans::Registry.default_plan.key
    assert_equal :starter, PricingPlans::Registry.highlighted_plan.key
  end

  # ========================================
  # USER PLAN RESOLUTION TESTS
  # ========================================

  def test_user_can_have_hidden_plan_as_current_plan
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :unsubscribed do
        price 0
        limit :projects, to: 0
        hidden!
        default!
      end

      config.plan :starter do
        price 10
        limit :projects, to: 5
      end
    end

    org = Organization.create!(name: "Test Org")

    # Organization without subscription should get default (hidden) plan
    current_plan = PricingPlans::PlanResolver.effective_plan_for(org)
    assert_equal :unsubscribed, current_plan.key
    assert current_plan.hidden?
  end

  def test_manual_assignment_to_hidden_plan_works
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :unsubscribed do
        price 0
        hidden!
        default!
      end

      config.plan :legacy_2023 do
        price 15
        hidden!  # Grandfathered plan
        limit :projects, to: 100
      end

      config.plan :starter do
        price 10
        limit :projects, to: 5
      end
    end

    org = Organization.create!(name: "Legacy Org")

    # Manually assign org to hidden grandfathered plan
    PricingPlans::PlanResolver.assign_plan_manually!(org, :legacy_2023, source: "admin_override")

    current_plan = PricingPlans::PlanResolver.effective_plan_for(org)
    assert_equal :legacy_2023, current_plan.key
    assert current_plan.hidden?
  end

  # ========================================
  # SUGGEST_NEXT_PLAN_FOR TESTS
  # ========================================

  def test_suggest_next_plan_for_never_suggests_hidden_plans
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :unsubscribed do
        price 0
        limit :projects, to: 0
        hidden!
        default!
      end

      config.plan :starter do
        price 10
        limit :projects, to: 5
      end

      config.plan :pro do
        price 20
        limit :projects, to: 50
      end
    end

    org = Organization.create!(name: "Test Org")

    # Organization is on :unsubscribed (hidden plan)
    # Should suggest first visible plan, not stay on hidden plan
    suggested = PricingPlans.suggest_next_plan_for(org)
    assert_equal :starter, suggested.key
    refute suggested.hidden?
  end

  def test_suggest_next_plan_for_with_usage_suggests_plan_that_satisfies_usage
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :unsubscribed do
        price 0
        limit :projects, to: 0
        hidden!
        default!
      end

      config.plan :starter do
        price 10
        limit :projects, to: 5
      end

      config.plan :pro do
        price 20
        limit :projects, to: 50
      end
    end

    org = Organization.create!(name: "Test Org")

    # Manually assign to :pro and create some projects
    PricingPlans::PlanResolver.assign_plan_manually!(org, :pro)
    3.times { |i| org.projects.create!(name: "Project #{i}") }

    # Now suggest next plan based on current usage
    suggested = PricingPlans.suggest_next_plan_for(org, keys: [:projects])

    # Current plan is :pro and it satisfies usage, so should stay on :pro
    # (not downgrade to :starter which only allows 5)
    assert_equal :pro, suggested.key
    refute suggested.hidden?
  end

  def test_suggest_next_plan_for_fallback_when_all_visible_plans_too_small
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :unsubscribed do
        price 0
        limit :projects, to: 0
        hidden!
        default!
      end

      config.plan :starter do
        price 10
        limit :projects, to: :unlimited
      end
    end

    org = Organization.create!(name: "Test Org")

    # Start on starter, create many projects, then manually move to hidden plan
    PricingPlans::PlanResolver.assign_plan_manually!(org, :starter)
    100.times { |i| org.projects.create!(name: "Project #{i}") }
    PricingPlans::PlanResolver.assign_plan_manually!(org, :unsubscribed)

    suggested = PricingPlans.suggest_next_plan_for(org, keys: [:projects])

    # :starter has unlimited projects, so it should satisfy
    assert_equal :starter, suggested.key
    refute suggested.hidden?
  end

  # ========================================
  # PAY INTEGRATION TESTS
  # ========================================

  def test_pay_subscription_can_resolve_to_hidden_grandfathered_plan
    # Ensure Pay is defined for these tests
    Object.const_set(:Pay, Module.new) unless defined?(Pay)

    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :unsubscribed do
        price 0
        hidden!
        default!
      end

      config.plan :legacy_2020 do
        stripe_price month: "price_legacy_2020"
        hidden!  # Old plan, no longer offered
        limit :projects, to: 200
      end

      config.plan :starter do
        stripe_price month: "price_starter_monthly"
        limit :projects, to: 5
      end
    end

    # Create org with payment_processor (Pattern B)
    org = OpenStruct.new(id: 123, class: Organization)

    # Create mock payment_processor with subscription to hidden legacy plan
    payment_processor = OpenStruct.new(
      id: "customer_123",
      class: OpenStruct.new(name: "Pay::Stripe::Customer")
    )

    subscription = OpenStruct.new(
      id: "sub_legacy",
      name: "legacy",
      processor_plan: "price_legacy_2020",  # Maps to hidden :legacy_2020 plan
      status: "active",
      class: OpenStruct.new(name: "Pay::Stripe::Subscription")
    )
    subscription.define_singleton_method(:active?) { true }
    subscription.define_singleton_method(:on_trial?) { false }
    subscription.define_singleton_method(:on_grace_period?) { false }

    subscriptions = [subscription]
    subscriptions.define_singleton_method(:to_a) { subscriptions }
    subscriptions.define_singleton_method(:count) { 1 }

    payment_processor.define_singleton_method(:subscriptions) { subscriptions }
    payment_processor.define_singleton_method(:respond_to?) do |method_name|
      [:subscriptions].include?(method_name) || super(method_name)
    end

    org.define_singleton_method(:payment_processor) { payment_processor }

    # Should resolve to hidden :legacy_2020 plan via Pay integration
    current_plan = PricingPlans::PlanResolver.effective_plan_for(org)
    assert_equal :legacy_2020, current_plan.key
    assert current_plan.hidden?, "Should resolve to hidden grandfathered plan"
  end

  # ========================================
  # EDGE CASE TESTS
  # ========================================

  def test_all_plans_hidden_returns_empty_array
    PricingPlans.configure do |config|
      config.plan :hidden1 do
        price 0
        hidden!
        default!
      end

      config.plan :hidden2 do
        price 10
        hidden!
      end
    end

    visible_plans = PricingPlans.plans
    assert_equal 0, visible_plans.size, "Should return empty array when all plans are hidden"
    assert_empty visible_plans
  end

  def test_suggest_next_plan_for_when_all_plans_hidden_returns_nil
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      config.plan :unsubscribed do
        price 0
        hidden!
        default!
      end
    end

    org = Organization.create!(name: "Test Org")

    suggested = PricingPlans.suggest_next_plan_for(org)
    assert_nil suggested, "Should return nil when all plans are hidden and no visible plans exist"
  end

  def test_hidden_plan_not_highlighted_by_default
    plan = PricingPlans::Plan.new(:test)
    plan.hidden!

    refute plan.highlighted?, "Hidden plan should not be highlighted by default"
  end

  def test_plan_can_be_default_and_hidden
    PricingPlans.configure do |config|
      config.plan :unsubscribed do
        price 0
        hidden!
        default!  # Both hidden and default is allowed
      end

      config.plan :starter do
        price 10
      end
    end

    default_plan = PricingPlans::Registry.default_plan
    assert default_plan.hidden?
    assert default_plan.default?
  end

  # ========================================
  # REAL-WORLD USE CASE TEST
  # ========================================

  def test_real_world_use_case_unsubscribed_users_dont_see_hidden_plan_on_pricing_page
    # This test simulates the demobusiness use case
    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"

      # Hidden default plan for users who haven't subscribed yet
      config.plan :unsubscribed do
        name "Pending Subscription"
        description "Subscribe to a plan to get started"
        price 0

        hidden!  # Don't show on pricing page

        # Block everything
        limit :icons, to: 0
        limit :downloads, to: 0, per: :month
        limit :projects, to: 0

        default!
      end

      config.plan :starter do
        name "Starter"
        stripe_price month: "price_starter_monthly", year: "price_starter_yearly"
        limit :icons, to: 100
        limit :downloads, to: 1000, per: :month
        limit :projects, to: 5
        highlighted!
      end

      config.plan :pro do
        name "Pro"
        stripe_price month: "price_pro_monthly", year: "price_pro_yearly"
        limit :icons, to: 500
        limit :downloads, to: :unlimited
        limit :projects, to: 25
      end
    end

    # New org signs up (no subscription yet)
    new_org = Organization.create!(name: "New Org")

    # Organization is on :unsubscribed plan (hidden, default)
    assert_equal :unsubscribed, new_org.current_pricing_plan.key
    assert new_org.current_pricing_plan.hidden?

    # Pricing page only shows visible plans
    pricing_plans = PricingPlans.for_pricing(plan_owner: new_org)
    assert_equal 2, pricing_plans.size, "Pricing page should only show starter and pro"
    assert_equal [:starter, :pro], pricing_plans.map { |p| p[:key] }

    # :unsubscribed should NOT appear
    refute pricing_plans.any? { |p| p[:key] == :unsubscribed }

    # Organization cannot create projects (limit is 0)
    refute new_org.within_plan_limits?(:projects)
    refute new_org.within_plan_limits?(:icons, by: 1)
  end
end
