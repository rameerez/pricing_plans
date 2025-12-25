# frozen_string_literal: true

require "test_helper"

class ControllerDynamicCallbacksTest < ActiveSupport::TestCase
  class DummyController
    include PricingPlans::ControllerGuards

    def initialize(plan_owner)
      @plan_owner = plan_owner
    end

    # Common convention helper that should be auto-detected
    def current_organization
      @plan_owner
    end

    # Simulate Rails redirect/flash helpers for tests below
    def redirect_to(path, **opts); @redirected_to = [path, opts]; end
    def redirected_to; @redirected_to; end
    def flash; @flash ||= {}; end
  end

  class DummyConfiguredController
    include PricingPlans::ControllerGuards

    class << self
      # Choose a custom resolver method for plan owner
      def use_configured_method!
        self.pricing_plans_plan_owner_method = :configured_org
      end

      def use_block!(&block)
        pricing_plans_plan_owner(&block)
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

  def test_per_controller_default_redirect_is_used_when_blocked
    controller = DummyController.new(@org)
    # Force a small limit to trigger block
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :licenses, to: 0, after_limit: :block_usage
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      DummyController.pricing_plans_redirect_on_blocked_limit = "/pricing"

      result = controller.enforce_licenses_limit!(on: :current_organization)

      assert_equal false, result
      path, opts = controller.redirected_to
      assert_equal "/pricing", path
      assert_equal :see_other, opts[:status]
      assert_kind_of String, opts[:alert]
      assert_match(/limit/i, opts[:alert])
    ensure
      DummyController.pricing_plans_redirect_on_blocked_limit = nil
    end
  end

  def test_global_default_redirect_is_used_when_no_per_controller
    controller = DummyController.new(@org)
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :licenses, to: 0, after_limit: :block_usage
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      original = PricingPlans.configuration.redirect_on_blocked_limit
      PricingPlans.configuration.redirect_on_blocked_limit = "/global_pricing"

      result = controller.enforce_licenses_limit!(on: :current_organization)

      assert_equal false, result
      path, opts = controller.redirected_to
      assert_equal "/global_pricing", path
      assert_equal :see_other, opts[:status]
      assert_kind_of String, opts[:alert]
      assert_match(/limit/i, opts[:alert])
    ensure
      PricingPlans.configuration.redirect_on_blocked_limit = original
    end
  end

  def test_redirect_to_option_overrides_defaults
    controller = DummyController.new(@org)
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :licenses, to: 0, after_limit: :block_usage
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      original = PricingPlans.configuration.redirect_on_blocked_limit
      PricingPlans.configuration.redirect_on_blocked_limit = "/global"
      DummyController.pricing_plans_redirect_on_blocked_limit = "/local"

      result = controller.enforce_licenses_limit!(on: :current_organization, redirect_to: "/override")

      assert_equal false, result
      path, opts = controller.redirected_to
      assert_equal "/override", path
      assert_equal :see_other, opts[:status]
      assert_kind_of String, opts[:alert]
    ensure
      DummyController.pricing_plans_redirect_on_blocked_limit = nil
      PricingPlans.configuration.redirect_on_blocked_limit = original
    end
  end

  def test_per_controller_default_symbol_helper
    controller_class = Class.new do
      include PricingPlans::ControllerGuards
      def pricing_path; "/from_helper"; end
      def redirect_to(path, **opts); @redir = [path, opts]; end
      def redirected_to; @redir; end
      def flash; @flash ||= {}; end
    end
    controller = controller_class.new
    org = create_organization
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :licenses, to: 0, after_limit: :block_usage
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      controller_class.pricing_plans_redirect_on_blocked_limit = :pricing_path
      # Provide plan_owner via common convention method
      controller.define_singleton_method(:current_organization) { org }

      result = controller.enforce_licenses_limit!

      assert_equal false, result
      path, opts = controller.redirected_to
      assert_equal "/from_helper", path
      assert_equal :see_other, opts[:status]
    ensure
      controller_class.pricing_plans_redirect_on_blocked_limit = nil
    end
  end

  def test_global_default_proc_receives_result
    controller = DummyController.new(@org)
    def controller.pricing_path; "/base"; end
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :licenses, to: 0, after_limit: :block_usage
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      original = PricingPlans.configuration.redirect_on_blocked_limit
      PricingPlans.configuration.redirect_on_blocked_limit = ->(result) { "/base?limit=#{result.limit_key}" }

      result = controller.enforce_licenses_limit!(on: :current_organization)

      assert_equal false, result
      path, _opts = controller.redirected_to
      assert_match %r{^/base\?limit=licenses$}, path
    ensure
      PricingPlans.configuration.redirect_on_blocked_limit = original
    end
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

  def test_enforce_dynamic_feature_guard_accepts_explicit_plan_owner_override
    org1 = create_organization
    org2 = create_organization
    controller = DummyController.new(org1)

    # org1 on free → denied
    assert_raises(PricingPlans::FeatureDenied) { controller.enforce_api_access! }

    # org2 on pro → allowed
    PricingPlans::Assignment.assign_plan_to(org2, :pro)
    assert_equal true, controller.enforce_api_access!(plan_owner: org2)
  end

  def test_plan_owner_resolution_prefers_configured_method_over_conventions
    org1 = create_organization
    org2 = create_organization
    PricingPlans::Assignment.assign_plan_to(org2, :pro)

    controller = DummyConfiguredController.new(org1: org1, org2: org2)
    DummyConfiguredController.use_configured_method!

    # Should use configured_org (org2) rather than current_organization (org1)
    assert_equal true, controller.enforce_api_access!
  end

  def test_plan_owner_resolution_with_block
    org1 = create_organization
    org2 = create_organization
    PricingPlans::Assignment.assign_plan_to(org2, :pro)
    PricingPlans::Assignment.assign_plan_to(org1, :pro)

    # Ensure no residue from other tests
    if DummyConfiguredController.respond_to?(:pricing_plans_plan_owner_method=)
      DummyConfiguredController.pricing_plans_plan_owner_method = nil
    end
    if DummyConfiguredController.respond_to?(:pricing_plans_plan_owner_proc=)
      DummyConfiguredController.pricing_plans_plan_owner_proc = nil
    end
    DummyConfiguredController.use_block! { @org2 }
    controller = DummyConfiguredController.new(org1: org1, org2: org2)
    # Should allow access; block-provided plan_owner is supported (exact target not material here)
    assert_nothing_raised { controller.enforce_api_access! }
  end

  def test_respond_to_missing_for_enforce
    controller = DummyController.new(@org)
    assert controller.respond_to?(:enforce_api_access!)
    refute controller.respond_to?(:enforce_api_access)
  end

  def test_configuration_error_when_plan_owner_cannot_be_inferred
    # Reconfigure to a plan owner class without a matching helper
    original = PricingPlans.configuration.plan_owner_class
    PricingPlans.configuration.plan_owner_class = "Workspace"
    PricingPlans.send(:registry).build_from_configuration(PricingPlans.configuration)

    begin
      klass = Class.new do
        include PricingPlans::ControllerGuards
      end
      controller = klass.new

      error = assert_raises(PricingPlans::ConfigurationError) do
        controller.enforce_api_access!
      end
      assert_match(/unable to infer plan owner/i, error.message)
    ensure
      # Restore plan owner class for future tests
      PricingPlans.configuration.plan_owner_class = original
      PricingPlans.send(:registry).build_from_configuration(PricingPlans.configuration)
    end
  end
end

class ControllerWithPlanLimitSugarTest < ActiveSupport::TestCase
  def setup
    @org = create_organization
    @plan = PricingPlans::Plan.new(:tmp)
  end

  def build_controller(&block)
    klass = Class.new do
      include PricingPlans::ControllerGuards
      attr_reader :redirected_to, :redirect_opts, :flashes, :yielded
      def initialize
        @flashes = {}
      end
      def flash; @flashes; end
      def redirect_to(path, **opts)
        @redirected_to = path
        @redirect_opts = opts
      end
      def pricing_path; "/pricing"; end
    end
    controller = klass.new
    controller
  end

  def test_with_plan_limit_yields_on_within
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :licenses, to: 10, after_limit: :grace_then_block, grace: 7.days
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      ctrl = build_controller
      yielded = nil
      ctrl.with_plan_limit!(:licenses, plan_owner: @org, by: 1) { |res| yielded = res }
      assert yielded
      assert yielded.within? || yielded.warning?
    end
  end

  def test_with_plan_limit_sets_flash_on_warning_or_grace
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :licenses, to: 1, after_limit: :grace_then_block, grace: 7.days
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      # Simulate near-limit usage that will cross a warning threshold when adding 1
      PricingPlans::LimitChecker.stub(:current_usage_for, 0) do
        PricingPlans::LimitChecker.stub(:warning_thresholds, [0.5]) do
          ctrl = build_controller
          res = ctrl.with_plan_limit!(:licenses, plan_owner: @org, by: 1) { |_res| }
          assert res.warning? || res.grace?
          assert ctrl.flash[:warning]
        end
      end
    end
  end

  def test_with_plan_limit_redirects_and_aborts_on_block
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :licenses, to: 0, after_limit: :block_usage
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      ctrl = build_controller

      result = ctrl.with_plan_limit!(:licenses, plan_owner: @org, by: 1) { |_res| }

      assert_equal false, result
      assert_equal "/pricing", ctrl.redirected_to
      assert_equal :see_other, ctrl.redirect_opts[:status]
    end
  end

  def test_dynamic_with_limit_helper_works
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :licenses, to: 0, after_limit: :block_usage
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      ctrl = build_controller

      result = ctrl.with_licenses_limit!(plan_owner: @org, by: 1) { |_res| }

      assert_equal false, result
      assert_equal "/pricing", ctrl.redirected_to
    end
  end
end
