# frozen_string_literal: true

require "test_helper"

class PlanOwnerHelpersTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan   = :free
      config.plan :free do
        limits :projects, to: 1
      end
    end
    # Re-register counters after reset
    Project.send(:limited_by_pricing_plans, :projects, plan_owner: :organization) if Project.respond_to?(:limited_by_pricing_plans)
  end

  def test_auto_includes_helpers_into_configured_billable
    org = Organization.new(name: "Acme")

    assert_respond_to org, :within_plan_limits?
    assert_respond_to org, :plan_limit_remaining
    assert_respond_to org, :plan_limit_percent_used
    assert_respond_to org, :current_pricing_plan
    assert_respond_to org, :assign_pricing_plan!
    assert_respond_to org, :remove_pricing_plan!
    assert_respond_to org, :plan_allows?
    assert_respond_to org, :pay_subscription_active?
    assert_respond_to org, :pay_on_trial?
    assert_respond_to org, :pay_on_grace_period?
    assert_respond_to org, :grace_active_for?
    assert_respond_to org, :grace_ends_at_for
    assert_respond_to org, :grace_remaining_seconds_for
    assert_respond_to org, :grace_remaining_days_for
    assert_respond_to org, :plan_blocked_for?

    # Smoke check a real call path
    assert_equal :free, org.current_pricing_plan.key
  end

  def test_englishy_sugar_methods_defined_from_associations
    # Organization has has_many :projects in test schema via Project model
    # Simulate declaration from billable side to define sugar methods
    unless Organization.method_defined?(:projects_within_plan_limits?)
      PricingPlans::PlanOwner.define_limit_sugar_methods(Organization, :projects)
    end

    org = create_organization
    assert_respond_to org, :projects_within_plan_limits?
    assert_respond_to org, :projects_remaining
    assert_respond_to org, :projects_percent_used
    assert_respond_to org, :projects_grace_active?
    assert_respond_to org, :projects_grace_ends_at
    assert_respond_to org, :projects_blocked?

    # Smoke-check calls
    org.projects.create!(name: "P1")
    assert_equal false, org.projects_within_plan_limits?(by: 1)
    assert (org.projects_remaining.is_a?(Integer) || org.projects_remaining == :unlimited)
    assert org.projects_percent_used.is_a?(Numeric)
  end

  def test_feature_sugar_plan_allows_dynamic
    org = Organization.create!(name: "Acme")
    # Default plan does not allow :api_access
    refute org.plan_allows_api_access?

    # Add a pro plan that allows the feature and assign it
    PricingPlans.configure do |config|
      config.plan :pro do
        allows :api_access
      end
    end
    PricingPlans::Assignment.assign_plan_to(org, :pro)
    assert org.plan_allows_api_access?
    assert_equal org.plan_allows?(:api_access), org.plan_allows_api_access?
  end

  def test_feature_sugar_respond_to_missing
    org = Organization.create!(name: "Acme")
    assert org.respond_to?(:plan_allows_api_access?)
    # Pattern-based predicate methods should be discoverable
    assert org.respond_to?(:plan_allows_completely_made_up_feature?)
    # Unknown features simply return false
    refute org.plan_allows_completely_made_up_feature?
  end

  def test_idempotent_inclusion_on_reconfigure
    org = Organization.new(name: "Acme")
    assert_respond_to org, :within_plan_limits?

    # Reconfigure shouldn't break inclusion or duplicate
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan   = :free
      config.plan :free do
        limits :projects, to: 1
      end
    end

    org2 = Organization.new(name: "Beta")
    assert_respond_to org2, :within_plan_limits?
  end

  def test_attach_helpers_when_billable_defined_after_config
    # Configure with a class name that does not exist yet
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.plan_owner_class = "LatePlanOwner"
      config.default_plan   = :free
      config.plan :free do
        limits :projects, to: 1
      end
    end

    # Define the class afterwards
    Object.const_set(:LatePlanOwner, Class.new)

    # Simulate engine's to_prepare hook by invoking the attachment helper
    PricingPlans::Registry.send(:attach_billable_helpers!)

    late = LatePlanOwner.new
    assert_respond_to late, :within_plan_limits?
    assert_respond_to late, :current_pricing_plan
  ensure
    Object.send(:remove_const, :LatePlanOwner) if defined?(LatePlanOwner)
  end
end
