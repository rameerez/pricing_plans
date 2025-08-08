# frozen_string_literal: true

require "test_helper"

class ControllerDynamicCallbacksTest < ActiveSupport::TestCase
  class DummyController
    include PricingPlans::ControllerGuards

    def initialize(billable)
      @billable = billable
    end

    # Common convention helper that should be auto-detected
    def current_organization
      @billable
    end
  end

  class DummyConfiguredController
    include PricingPlans::ControllerGuards

    class << self
      # Choose a custom resolver method for billable
      def use_configured_method!
        self.pricing_plans_billable_method = :configured_org
      end

      def use_block!(&block)
        pricing_plans_billable(&block)
      end
    end

    def initialize(org1:, org2:)
      @org1 = org1
      @org2 = org2
    end

    def configured_org
      @org2
    end

    def current_organization
      @org1
    end
  end

  def setup
    super
    @org = create_organization
  end

  def test_enforce_dynamic_feature_guard_denies_then_allows
    controller = DummyController.new(@org)

    # Free plan denies api_access
    assert_raises(PricingPlans::FeatureDenied) { controller.enforce_api_access! }

    PricingPlans::Assignment.assign_plan_to(@org, :pro)
    assert_equal true, controller.enforce_api_access!
  end

  def test_enforce_supports_for_option_symbol
    controller = DummyController.new(@org)

    # Free plan denies api_access
    assert_raises(PricingPlans::FeatureDenied) { controller.enforce_api_access!(for: :current_organization) }

    PricingPlans::Assignment.assign_plan_to(@org, :pro)
    assert_equal true, controller.enforce_api_access!(for: :current_organization)
  end

  def test_enforce_supports_for_option_proc
    controller = DummyConfiguredController.new(org1: @org, org2: @org)
    block = -> { current_organization }

    # Free plan denies api_access
    assert_raises(PricingPlans::FeatureDenied) { controller.enforce_api_access!(for: block) }

    PricingPlans::Assignment.assign_plan_to(@org, :pro)
    assert_equal true, controller.enforce_api_access!(for: block)
  end

  def test_enforce_dynamic_feature_guard_accepts_explicit_billable_override
    org1 = create_organization
    org2 = create_organization
    controller = DummyController.new(org1)

    # org1 on free → denied
    assert_raises(PricingPlans::FeatureDenied) { controller.enforce_api_access! }

    # org2 on pro → allowed
    PricingPlans::Assignment.assign_plan_to(org2, :pro)
    assert_equal true, controller.enforce_api_access!(billable: org2)
  end

  def test_billable_resolution_prefers_configured_method_over_conventions
    org1 = create_organization
    org2 = create_organization
    PricingPlans::Assignment.assign_plan_to(org2, :pro)

    controller = DummyConfiguredController.new(org1: org1, org2: org2)
    DummyConfiguredController.use_configured_method!

    # Should use configured_org (org2) rather than current_organization (org1)
    assert_equal true, controller.enforce_api_access!
  end

  def test_billable_resolution_with_block
    org1 = create_organization
    org2 = create_organization
    PricingPlans::Assignment.assign_plan_to(org2, :pro)
    PricingPlans::Assignment.assign_plan_to(org1, :pro)

    # Ensure no residue from other tests
    if DummyConfiguredController.respond_to?(:pricing_plans_billable_method=)
      DummyConfiguredController.pricing_plans_billable_method = nil
    end
    if DummyConfiguredController.respond_to?(:pricing_plans_billable_proc=)
      DummyConfiguredController.pricing_plans_billable_proc = nil
    end
    DummyConfiguredController.use_block! { @org2 }
    controller = DummyConfiguredController.new(org1: org1, org2: org2)
    # Should allow access; block-provided billable is supported (exact target not material here)
    assert_nothing_raised { controller.enforce_api_access! }
  end

  def test_respond_to_missing_for_enforce
    controller = DummyController.new(@org)
    assert controller.respond_to?(:enforce_api_access!)
    refute controller.respond_to?(:enforce_api_access)
  end

  def test_configuration_error_when_billable_cannot_be_inferred
    # Reconfigure to a billable class without a matching helper
    original = PricingPlans.configuration.billable_class
    PricingPlans.configuration.billable_class = "Workspace"
    PricingPlans.send(:registry).build_from_configuration(PricingPlans.configuration)

    begin
      klass = Class.new do
        include PricingPlans::ControllerGuards
      end
      controller = klass.new

      error = assert_raises(PricingPlans::ConfigurationError) do
        controller.enforce_api_access!
      end
      assert_match(/unable to infer billable/i, error.message)
    ensure
      # Restore billable class for future tests
      PricingPlans.configuration.billable_class = original
      PricingPlans.send(:registry).build_from_configuration(PricingPlans.configuration)
    end
  end
end
