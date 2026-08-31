# frozen_string_literal: true

require "test_helper"

class PlanOverrideApiTest < ActiveSupport::TestCase
  def test_plan_owner_exposes_explicit_override_vocabulary
    organization = create_organization

    assert_respond_to organization, :override_pricing_plan!
    assert_respond_to organization, :clear_pricing_plan_override!
    assert_respond_to organization, :pricing_plan_overridden?
    assert_respond_to organization, :pricing_plan_override
    assert_respond_to organization, :pricing_plan_override_source
  end

  def test_override_inspection_is_safe_for_an_unsaved_plan_owner
    organization = Organization.new(name: "Not persisted yet")

    refute organization.pricing_plan_overridden?
    assert_nil organization.pricing_plan_override
    assert_nil organization.pricing_plan_override_source
  end

  def test_pricing_plans_exposes_a_gem_specific_deprecator
    assert_instance_of ActiveSupport::Deprecation, PricingPlans.deprecator
    assert_equal "pricing_plans", PricingPlans.deprecator.gem_name
    assert_equal "0.6.0", PricingPlans.deprecator.deprecation_horizon
  end

  def test_explicit_override_requires_a_source
    organization = create_organization

    error = assert_raises(ArgumentError) do
      organization.override_pricing_plan!(:pro)
    end

    assert_match(/missing keyword: :source/, error.message)
    refute organization.pricing_plan_overridden?
  end

  def test_explicit_override_rejects_a_blank_source
    organization = create_organization

    assert_raises(ActiveRecord::RecordInvalid) do
      organization.override_pricing_plan!(:pro, source: "")
    end

    refute organization.pricing_plan_overridden?
  end

  def test_explicit_override_creates_a_self_describing_override
    organization = create_organization

    override = organization.override_pricing_plan!(:pro, source: "customer_success_gift")

    assert_equal override, organization.pricing_plan_override
    assert_equal "pro", override.plan_key
    assert_equal "customer_success_gift", organization.pricing_plan_override_source
    assert organization.pricing_plan_overridden?

    resolution = organization.current_pricing_plan_resolution
    assert resolution.pricing_plan_overridden?
    assert_equal override, resolution.pricing_plan_override
    assert_equal "customer_success_gift", resolution.pricing_plan_override_source

    resolution_hash = resolution.to_h
    assert resolution_hash[:pricing_plan_overridden]
    assert_equal override, resolution_hash[:pricing_plan_override]
    assert_equal "customer_success_gift", resolution_hash[:pricing_plan_override_source]
  end

  def test_explicit_override_accepts_a_symbol_source_and_persists_it_as_provenance_text
    organization = create_organization

    override = organization.override_pricing_plan!(:pro, source: :employee_access)

    assert_equal "employee_access", override.source
    assert_equal "employee_access", organization.pricing_plan_override_source
  end

  def test_explicit_override_updates_the_single_existing_override
    organization = create_organization
    original = organization.override_pricing_plan!(:pro, source: "support")

    updated = organization.override_pricing_plan!(:enterprise, source: "account_manager")

    assert_equal original.id, updated.id
    assert_equal "enterprise", updated.plan_key
    assert_equal "account_manager", updated.source
    assert_equal 1, PricingPlans::Assignment.where(plan_owner: organization).count
  end

  def test_explicitly_overriding_to_the_default_plan_remains_supported
    organization = create_organization(
      pay_subscription: { active: true, processor_plan: "price_pro_123" }
    )

    override = organization.override_pricing_plan!(:free, source: "admin_downgrade")
    resolution = organization.current_pricing_plan_resolution

    assert_equal :free, resolution.plan_key
    assert resolution.pricing_plan_overridden?
    assert_equal override, resolution.pricing_plan_override
    assert_equal "admin_downgrade", resolution.pricing_plan_override_source
    assert_equal "price_pro_123", resolution.subscription.processor_plan
  end

  def test_explicit_api_is_allowed_even_when_legacy_default_assignments_are_strictly_rejected
    PricingPlans.configuration.legacy_default_plan_assignment_behavior = :raise
    organization = create_organization

    assert_nothing_raised do
      organization.override_pricing_plan!(:free, source: "intentional_default_tier_pin")
    end

    assert organization.pricing_plan_overridden?
  end

  def test_explicit_override_and_clear_apis_never_emit_legacy_deprecations
    PricingPlans.configuration.legacy_default_plan_assignment_behavior = :raise
    organization = create_organization

    with_captured_pricing_plans_deprecations do |messages|
      organization.override_pricing_plan!(:free, source: "intentional_default_tier_pin")
      organization.clear_pricing_plan_override!

      assert_empty messages
    end
  end

  def test_clearing_an_override_restores_subscription_resolution_without_changing_billing
    organization = create_organization(
      pay_subscription: { active: true, processor_plan: "price_pro_123" }
    )
    subscription = organization.subscription
    organization.override_pricing_plan!(:free, source: "temporary_support_downgrade")

    removed_overrides = organization.clear_pricing_plan_override!
    resolution = organization.current_pricing_plan_resolution

    assert_equal 1, removed_overrides.length
    refute organization.pricing_plan_overridden?
    assert_equal :subscription, resolution.source
    assert_equal :pro, resolution.plan_key
    assert_equal subscription.processor_plan, resolution.subscription.processor_plan
  end

  def test_clearing_an_override_restores_default_resolution_when_there_is_no_subscription
    organization = create_organization
    organization.override_pricing_plan!(:enterprise, source: "demo")

    organization.clear_pricing_plan_override!

    assert_equal :default, organization.current_pricing_plan_source
    assert_equal :free, organization.current_pricing_plan.key
    refute organization.pricing_plan_overridden?
    assert_nil organization.pricing_plan_override
    assert_nil organization.pricing_plan_override_source
  end

  def test_clearing_an_override_is_idempotent
    organization = create_organization

    assert_empty organization.clear_pricing_plan_override!
    assert_empty organization.clear_pricing_plan_override!
  end

  def test_plan_resolver_exposes_explicit_override_operations
    organization = create_organization

    override = PricingPlans::PlanResolver.override_pricing_plan_for!(
      organization,
      :pro,
      source: "support"
    )

    assert_equal "pro", override.plan_key
    assert_equal "support", override.source
    assert_equal :pro, PricingPlans::PlanResolver.plan_key_for(organization)

    PricingPlans::PlanResolver.clear_pricing_plan_override_for!(organization)

    assert_equal :free, PricingPlans::PlanResolver.plan_key_for(organization)
  end

  def test_assignment_model_exposes_explicit_override_persistence_operations
    organization = create_organization

    override = PricingPlans::Assignment.create_or_update_pricing_plan_override_for!(
      organization,
      :pro,
      source: "support"
    )

    assert_equal "pro", override.plan_key
    assert_equal "support", override.source

    removed_overrides = PricingPlans::Assignment.clear_pricing_plan_override_for!(organization)

    assert_equal [override], removed_overrides
    refute override.class.exists?(override.id)
  end

  def test_limitable_model_class_exposes_an_explicit_owner_aware_override_operation
    organization = create_organization

    override = Project.override_pricing_plan_for!(organization, :pro, source: "test_setup")

    assert_equal organization, override.plan_owner
    assert_equal "pro", override.plan_key
    assert_equal "test_setup", override.source

    removed_overrides = Project.clear_pricing_plan_override_for!(organization)

    assert_equal [override], removed_overrides
    refute organization.pricing_plan_overridden?
  end

  def test_override_uniqueness_is_scoped_to_both_polymorphic_owner_type_and_id
    shared_id = 9_999_999
    organization = Organization.create!(id: shared_id, name: "Organization owner")
    project = Project.create!(id: shared_id, organization: organization, name: "Project owner")

    organization_override = PricingPlans::Assignment.create_or_update_pricing_plan_override_for!(
      organization,
      :pro,
      source: "organization_override"
    )
    project_override = PricingPlans::Assignment.create_or_update_pricing_plan_override_for!(
      project,
      :enterprise,
      source: "project_override"
    )

    assert_equal shared_id, organization_override.plan_owner_id
    assert_equal shared_id, project_override.plan_owner_id
    assert_equal "Organization", organization_override.plan_owner_type
    assert_equal "Project", project_override.plan_owner_type
    assert_equal 2, PricingPlans::Assignment.where(plan_owner_id: shared_id).count
  end

  def test_legacy_plan_owner_assignment_api_warns_and_preserves_its_existing_behavior
    organization = create_organization

    with_captured_pricing_plans_deprecations do |messages|
      override = organization.assign_pricing_plan!(:pro)

      assert_equal "pro", override.plan_key
      assert_equal "manual", override.source
      assert_equal 1, messages.length
      assert_includes messages.first, "assign_pricing_plan!"
      assert_includes messages.first, "override_pricing_plan!"
    end
  end

  def test_legacy_default_plan_assignment_warns_about_the_persistent_override_by_default
    organization = create_organization

    with_captured_pricing_plans_deprecations do |messages|
      organization.assign_pricing_plan!(:free)

      assert_equal 1, messages.length
      assert_includes messages.first, "configured default plan :free"
      assert_includes messages.first, "persistent pricing plan override"
      assert_includes messages.first, "clear_pricing_plan_override!"
    end

    assert organization.pricing_plan_overridden?
  end

  def test_legacy_default_plan_assignment_can_be_rejected_before_it_writes_any_state
    PricingPlans.configuration.legacy_default_plan_assignment_behavior = :raise
    organization = create_organization

    error = assert_raises(PricingPlans::LegacyDefaultPlanAssignmentError) do
      organization.assign_pricing_plan!(:free)
    end

    assert_includes error.message, "configured default plan :free"
    assert_includes error.message, "override_pricing_plan!(:free, source:"
    assert_includes error.message, "clear_pricing_plan_override!"
    assert_equal :free, error.configured_default_plan_key
    assert_equal "assign_pricing_plan!", error.legacy_assignment_method_name
    refute organization.pricing_plan_overridden?
  end

  def test_legacy_default_plan_assignment_guard_recognizes_string_plan_keys
    PricingPlans.configuration.legacy_default_plan_assignment_behavior = :raise
    organization = create_organization

    assert_raises(PricingPlans::LegacyDefaultPlanAssignmentError) do
      organization.assign_pricing_plan!("free")
    end

    refute organization.pricing_plan_overridden?
  end

  def test_legacy_default_plan_assignment_guard_can_be_explicitly_allowed_during_migration
    PricingPlans.configuration.legacy_default_plan_assignment_behavior = :allow
    organization = create_organization

    with_captured_pricing_plans_deprecations do |messages|
      organization.assign_pricing_plan!(:free)

      assert_equal 1, messages.length
      assert_includes messages.first, "assign_pricing_plan!"
      refute_includes messages.first, "configured default plan :free"
    end

    assert organization.pricing_plan_overridden?
  end

  def test_invalid_runtime_legacy_default_plan_assignment_behavior_fails_closed
    PricingPlans.configuration.legacy_default_plan_assignment_behavior = :unexpected
    organization = create_organization

    error = assert_raises(PricingPlans::ConfigurationError) do
      organization.assign_pricing_plan!(:free)
    end

    assert_includes error.message, "legacy_default_plan_assignment_behavior"
    refute organization.pricing_plan_overridden?
  end

  def test_newly_generated_initializers_enable_the_strict_legacy_default_plan_guard
    template = File.read(
      File.expand_path(
        "../lib/generators/pricing_plans/install/templates/initializer.rb",
        __dir__
      )
    )

    assert_includes template, "config.legacy_default_plan_assignment_behavior = :raise"
  end

  def test_newly_generated_assignment_tables_require_explicit_source_provenance
    template = File.read(
      File.expand_path(
        "../lib/generators/pricing_plans/install/templates/create_pricing_plans_tables.rb.erb",
        __dir__
      )
    )

    assert_includes template, "t.string :source, null: false"
    refute_includes template, "t.string :source, null: false, default:"
  end

  def test_every_legacy_assignment_entry_point_uses_the_same_default_plan_guard
    legacy_calls = {
      "PricingPlans::PlanResolver.assign_plan_manually!" => lambda { |organization|
        PricingPlans::PlanResolver.assign_plan_manually!(organization, :free)
      },
      "PricingPlans::Assignment.assign_plan_to" => lambda { |organization|
        PricingPlans::Assignment.assign_plan_to(organization, :free)
      },
      "Project.assign_pricing_plan!" => lambda { |organization|
        Project.assign_pricing_plan!(organization, :free)
      }
    }

    PricingPlans.configuration.legacy_default_plan_assignment_behavior = :raise

    legacy_calls.each do |expected_method_name, legacy_call|
      organization = create_organization

      error = assert_raises(PricingPlans::LegacyDefaultPlanAssignmentError) do
        legacy_call.call(organization)
      end

      assert_includes error.message, expected_method_name
      refute organization.pricing_plan_overridden?
    end
  end

  def test_every_legacy_removal_entry_point_warns_and_clears_any_override_source
    legacy_calls = {
      "remove_pricing_plan!" => ->(organization) { organization.remove_pricing_plan! },
      "PricingPlans::PlanResolver.remove_manual_assignment!" => lambda { |organization|
        PricingPlans::PlanResolver.remove_manual_assignment!(organization)
      },
      "PricingPlans::Assignment.remove_assignment_for" => lambda { |organization|
        PricingPlans::Assignment.remove_assignment_for(organization)
      }
    }

    legacy_calls.each do |expected_method_name, legacy_call|
      organization = create_organization
      organization.override_pricing_plan!(:pro, source: "admin")

      with_captured_pricing_plans_deprecations do |messages|
        legacy_call.call(organization)

        assert_equal 1, messages.length
        assert_includes messages.first, expected_method_name
        assert_includes messages.first, "clear_pricing_plan_override!"
      end

      refute organization.pricing_plan_overridden?
    end
  end

  private

  def with_captured_pricing_plans_deprecations
    deprecator = PricingPlans.deprecator
    original_behavior = deprecator.behavior
    messages = []
    deprecator.behavior = ->(message, _callstack, _deprecator) { messages << message }

    yield messages
  ensure
    deprecator.behavior = original_behavior
  end
end
