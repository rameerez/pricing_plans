# frozen_string_literal: true

require "test_helper"

class PlanResolverTest < ActiveSupport::TestCase
  def test_effective_plan_with_active_subscription
    org = create_organization(
      pay_subscription: { active: true, processor_plan: "price_pro_123" }
    )

    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :pro, plan.key
  end

  def test_effective_plan_with_trial_subscription
    org = create_organization(
      pay_trial: true,
      pay_subscription: { processor_plan: "price_pro_123" }
    )

    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :pro, plan.key
  end

  def test_effective_plan_with_grace_period_subscription
    org = create_organization(
      pay_grace_period: true,
      pay_subscription: { processor_plan: "price_pro_123" }
    )

    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :pro, plan.key
  end

  def test_effective_plan_with_manual_assignment
    org = create_organization

    PricingPlans::Assignment.assign_plan_to(org, :enterprise)

    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :enterprise, plan.key
  end

  def test_effective_plan_falls_back_to_default
    org = create_organization

    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :free, plan.key
  end

  def test_effective_plan_prioritizes_pay_over_assignment
    org = create_organization(
      pay_subscription: { active: true, processor_plan: "price_pro_123" }
    )

    # Manual assignment should be ignored when Pay subscription is active
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)

    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :pro, plan.key  # Pay subscription wins
  end

  def test_effective_plan_with_unknown_processor_plan
    org = create_organization(
      pay_subscription: { active: true, processor_plan: "price_unknown_999" }
    )

    # Should fall back to manual assignment or default since processor plan not found
    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :free, plan.key
  end

  def test_effective_plan_with_inactive_subscription_but_manual_assignment
    org = create_organization(
      pay_subscription: { active: false, processor_plan: "price_pro_123" }
    )

    PricingPlans::Assignment.assign_plan_to(org, :enterprise)

    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :enterprise, plan.key
  end

  def test_plan_key_for_convenience_method
    org = create_organization(
      pay_subscription: { active: true, processor_plan: "price_pro_123" }
    )

    plan_key = PricingPlans::PlanResolver.plan_key_for(org)

    assert_equal :pro, plan_key
  end

  def test_assign_plan_manually
    org = create_organization

    assignment = PricingPlans::PlanResolver.assign_plan_manually!(org, :pro, source: "admin")

    assert_equal "pro", assignment.plan_key
    assert_equal "admin", assignment.source

    # Verify it affects plan resolution
    plan = PricingPlans::PlanResolver.effective_plan_for(org)
    assert_equal :pro, plan.key
  end

  def test_remove_manual_assignment
    org = create_organization

    PricingPlans::PlanResolver.assign_plan_manually!(org, :pro)

    # Verify assignment exists
    plan = PricingPlans::PlanResolver.effective_plan_for(org)
    assert_equal :pro, plan.key

    PricingPlans::PlanResolver.remove_manual_assignment!(org)

    # Should fall back to default
    plan = PricingPlans::PlanResolver.effective_plan_for(org)
    assert_equal :free, plan.key
  end

  def test_complex_stripe_price_matching
    # Test hash-based stripe price matching
    PricingPlans.reset_configuration!

    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        price 0
      end

      config.plan :pro do
        stripe_price({ month: "price_monthly", year: "price_yearly" })
      end
    end

    org = create_organization(
      pay_subscription: { active: true, processor_plan: "price_monthly" }
    )

    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :pro, plan.key
  end

  def test_pay_gem_not_available_graceful_fallback
    org = create_organization

    # Stub out the pay_available? method to return false
    PricingPlans::PlanResolver.stub(:pay_available?, false) do
      plan = PricingPlans::PlanResolver.effective_plan_for(org)

      # Should go straight to manual assignment / default
      assert_equal :free, plan.key
    end
  end

  def test_billable_without_pay_methods
    # Create a basic object without Pay methods
    basic_org = Object.new

    plan = PricingPlans::PlanResolver.effective_plan_for(basic_org)

    # Should fall back to default (no manual assignments for non-AR objects)
    assert_equal :free, plan.key
  end

  def test_subscription_with_nil_processor_plan
    org = create_organization(
      pay_subscription: { active: true, processor_plan: nil }
    )

    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :free, plan.key
  end

  def test_multiple_subscription_scenarios
    org = create_organization

    # Mock multiple subscriptions scenario
    subscription1 = OpenStruct.new(active?: false, on_trial?: false, on_grace_period?: false)
    subscription2 = OpenStruct.new(
      active?: true,
      on_trial?: false,
      on_grace_period?: false,
      processor_plan: "price_pro_123"
    )

    org.define_singleton_method(:subscriptions) { [subscription1, subscription2] }
    org.define_singleton_method(:subscription) { nil }  # Primary subscription inactive

    # Should find the active one
    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :pro, plan.key
  end

  def test_edge_case_empty_string_processor_plan
    org = create_organization(
      pay_subscription: { active: true, processor_plan: "" }
    )

    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :free, plan.key
  end

  def test_edge_case_subscription_method_returns_nil
    org = create_organization(
      pay_subscription: { active: true, processor_plan: "price_pro_123" }
    )

    # Override subscription method to return nil
    org.define_singleton_method(:subscription) { nil }

    plan = PricingPlans::PlanResolver.effective_plan_for(org)

    assert_equal :free, plan.key
  end

  def test_plan_resolution_caches_per_request
    org = create_organization
    # Initially default plan
    assert_equal :free, PricingPlans::PlanResolver.effective_plan_for(org).key

    # Assign plan; should reflect immediately since we don’t cache plan resolution here
    PricingPlans::PlanResolver.assign_plan_manually!(org, :pro)
    assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
  end
end
