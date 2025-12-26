# frozen_string_literal: true

require "test_helper"

class PlanResolverPaymentProcessorTest < ActiveSupport::TestCase
  # These tests verify the fix for the bug where pricing_plans failed to detect
  # subscriptions when using the payment_processor pattern (Pattern B) instead of
  # including Pay::Billable directly on the model (Pattern A).
  #
  # Bug: The gem checked if plan_owner.respond_to?(:subscribed?) before checking
  # for payment_processor, causing it to skip Pay integration for Pattern B apps.

  def setup
    super
    # Ensure Pay is defined for these tests
    Object.const_set(:Pay, Module.new) unless defined?(Pay)

    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
      config.plan :pro do
        stripe_price month: "price_pro_monthly", year: "price_pro_yearly"
      end
      config.plan :premium do
        stripe_price month: "price_premium_monthly"
      end
    end
  end

  def test_detects_subscription_via_payment_processor_without_direct_pay_methods
    # This is the core regression test for the bug fix
    # Simulates a User model that uses pay_customer (Pattern B)
    user = create_user_with_payment_processor(
      subscription_name: "pro",
      processor_plan: "price_pro_monthly",
      active: true
    )

    # User does NOT respond to Pay methods directly
    refute user.respond_to?(:subscribed?), "User should not have subscribed? method directly"
    refute user.respond_to?(:on_trial?), "User should not have on_trial? method directly"
    refute user.respond_to?(:subscriptions), "User should not have subscriptions association directly"

    # But DOES have payment_processor
    assert user.respond_to?(:payment_processor), "User should have payment_processor method"

    # Should correctly detect the subscription and return :pro plan
    plan = PricingPlans::PlanResolver.effective_plan_for(user)
    assert_equal :pro, plan.key, "Should detect pro plan via payment_processor"
  end

  def test_supports_custom_subscription_names_not_default
    # Regression test: The bug was also triggered by calling pp.subscription()
    # without a name parameter, which defaults to Pay.default_product_name ("default").
    # Users with custom-named subscriptions (like "pro", "premium") would fail.

    user = create_user_with_payment_processor(
      subscription_name: "my_custom_plan",  # NOT "default"
      processor_plan: "price_pro_monthly",
      active: true
    )

    plan = PricingPlans::PlanResolver.effective_plan_for(user)
    assert_equal :pro, plan.key, "Should detect subscription regardless of its name"
  end

  def test_finds_active_subscription_among_multiple
    # Users often have multiple subscriptions (old canceled ones + current active)
    # The fix ensures we iterate through ALL subscriptions to find the active one

    user = create_user_with_multiple_subscriptions([
      { name: "old_plan", processor_plan: "price_old", active: false },
      { name: "pro", processor_plan: "price_pro_monthly", active: true },
      { name: "canceled", processor_plan: "price_premium_monthly", active: false }
    ])

    plan = PricingPlans::PlanResolver.effective_plan_for(user)
    assert_equal :pro, plan.key, "Should find the active subscription among multiple"
  end

  def test_payment_processor_takes_precedence_over_direct_methods
    # Edge case: What if an app has BOTH payment_processor AND direct Pay methods?
    # payment_processor should take precedence (it's the newer pattern)

    user = create_user_with_both_patterns(
      payment_processor_plan: "price_pro_monthly",  # Should use this
      direct_plan: "price_premium_monthly"          # Should ignore this
    )

    plan = PricingPlans::PlanResolver.effective_plan_for(user)
    assert_equal :pro, plan.key, "payment_processor should take precedence over direct methods"
  end

  def test_falls_back_to_direct_methods_when_no_payment_processor
    # Pattern A apps (using include Pay::Billable) should still work
    user = create_user_with_direct_pay_methods(
      processor_plan: "price_premium_monthly",
      active: true
    )

    refute user.respond_to?(:payment_processor), "User should not have payment_processor"
    assert user.respond_to?(:subscribed?), "User should have subscribed? method directly"

    plan = PricingPlans::PlanResolver.effective_plan_for(user)
    assert_equal :premium, plan.key, "Should work with direct Pay methods (Pattern A)"
  end

  def test_handles_payment_processor_returning_nil
    # Edge case: payment_processor exists but returns nil (no Pay::Customer record)
    user = OpenStruct.new(id: 123, class: User)
    user.define_singleton_method(:payment_processor) { nil }

    plan = PricingPlans::PlanResolver.effective_plan_for(user)
    assert_equal :free, plan.key, "Should fall back to default when payment_processor is nil"
  end

  def test_handles_empty_subscriptions_collection
    # payment_processor exists but has no subscriptions
    user = create_user_with_payment_processor_no_subscriptions

    plan = PricingPlans::PlanResolver.effective_plan_for(user)
    assert_equal :free, plan.key, "Should fall back to default when no subscriptions exist"
  end

  private

  def create_user_with_payment_processor(subscription_name:, processor_plan:, active:)
    user = OpenStruct.new(id: 123, class: User)

    # Create mock payment_processor (Pay::Customer)
    payment_processor = OpenStruct.new(
      id: "customer_123",
      class: OpenStruct.new(name: "Pay::Stripe::Customer")
    )

    # Create mock subscription
    subscription = OpenStruct.new(
      id: "sub_123",
      name: subscription_name,
      processor_plan: processor_plan,
      status: active ? "active" : "canceled",
      class: OpenStruct.new(name: "Pay::Stripe::Subscription")
    )
    subscription.define_singleton_method(:active?) { active }
    subscription.define_singleton_method(:on_trial?) { false }
    subscription.define_singleton_method(:on_grace_period?) { false }

    # Mock subscriptions association
    subscriptions = [subscription]
    subscriptions.define_singleton_method(:to_a) { subscriptions }
    subscriptions.define_singleton_method(:count) { subscriptions.length }

    payment_processor.define_singleton_method(:subscriptions) { subscriptions }
    payment_processor.define_singleton_method(:respond_to?) do |method_name|
      [:subscriptions].include?(method_name) || super(method_name)
    end

    user.define_singleton_method(:payment_processor) { payment_processor }

    user
  end

  def create_user_with_multiple_subscriptions(subscription_configs)
    user = OpenStruct.new(id: 123, class: User)

    payment_processor = OpenStruct.new(
      id: "customer_123",
      class: OpenStruct.new(name: "Pay::Stripe::Customer")
    )

    subscriptions = subscription_configs.map do |config|
      sub = OpenStruct.new(
        id: "sub_#{rand(1000)}",
        name: config[:name],
        processor_plan: config[:processor_plan],
        status: config[:active] ? "active" : "canceled",
        class: OpenStruct.new(name: "Pay::Stripe::Subscription")
      )
      sub.define_singleton_method(:active?) { config[:active] }
      sub.define_singleton_method(:on_trial?) { false }
      sub.define_singleton_method(:on_grace_period?) { false }
      sub
    end

    subscriptions.define_singleton_method(:to_a) { subscriptions }
    subscriptions.define_singleton_method(:count) { subscriptions.length }

    payment_processor.define_singleton_method(:subscriptions) { subscriptions }
    payment_processor.define_singleton_method(:respond_to?) do |method_name|
      [:subscriptions].include?(method_name) || super(method_name)
    end

    user.define_singleton_method(:payment_processor) { payment_processor }

    user
  end

  def create_user_with_both_patterns(payment_processor_plan:, direct_plan:)
    user = create_user_with_payment_processor(
      subscription_name: "pro",
      processor_plan: payment_processor_plan,
      active: true
    )

    # Add direct Pay methods (Pattern A) in addition to payment_processor (Pattern B)
    user.define_singleton_method(:subscribed?) { true }
    user.define_singleton_method(:subscription) do
      OpenStruct.new(
        processor_plan: direct_plan,
        active?: true,
        on_trial?: false,
        on_grace_period?: false
      )
    end

    user
  end

  def create_user_with_direct_pay_methods(processor_plan:, active:)
    user = OpenStruct.new(id: 123, class: User)

    subscription = OpenStruct.new(
      processor_plan: processor_plan,
      status: active ? "active" : "canceled",
      class: OpenStruct.new(name: "Pay::Stripe::Subscription")
    )
    subscription.define_singleton_method(:active?) { active }
    subscription.define_singleton_method(:on_trial?) { false }
    subscription.define_singleton_method(:on_grace_period?) { false }

    user.define_singleton_method(:subscribed?) { active }
    user.define_singleton_method(:on_trial?) { false }
    user.define_singleton_method(:on_grace_period?) { false }
    user.define_singleton_method(:subscription) { subscription }

    user
  end

  def create_user_with_payment_processor_no_subscriptions
    user = OpenStruct.new(id: 123, class: User)

    payment_processor = OpenStruct.new(
      id: "customer_123",
      class: OpenStruct.new(name: "Pay::Stripe::Customer")
    )

    subscriptions = []
    subscriptions.define_singleton_method(:to_a) { [] }
    subscriptions.define_singleton_method(:count) { 0 }

    payment_processor.define_singleton_method(:subscriptions) { subscriptions }
    payment_processor.define_singleton_method(:respond_to?) do |method_name|
      [:subscriptions].include?(method_name) || super(method_name)
    end

    user.define_singleton_method(:payment_processor) { payment_processor }

    user
  end

  class User
    def self.name
      "User"
    end
  end
end
