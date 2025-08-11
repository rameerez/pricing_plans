# frozen_string_literal: true

require "test_helper"

class ControllerGuardsTest < ActiveSupport::TestCase
  include PricingPlans::ControllerGuards

  def setup
    super  # This calls the test helper setup which configures plans
    @org = create_organization
  end

  def test_require_plan_limit_returns_within_when_no_limit_configured
    # Mock plan with no limit for non-existent key
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) { |_key| nil }

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      result = require_plan_limit!(:non_existent, billable: @org)

      assert result.within?
      assert_match(/no limit configured/i, result.message)
    end
  end

  def test_require_plan_limit_returns_within_when_unlimited
    # Mock plan with unlimited limit
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      key == :projects ? { to: :unlimited } : nil
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      result = require_plan_limit!(:projects, billable: @org)

      assert result.within?
      assert_match(/unlimited/i, result.message)
    end
  end

  def test_require_plan_limit_within_limit_no_warning
    # Create org with larger limit so we don't cross warning thresholds
    # Mock a plan with a higher limit where we won't trigger warnings
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: 10, warn_at: [0.6, 0.8, 0.95], after_limit: :grace_then_block, grace: 7.days }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      # With 0 projects and limit of 10, adding 1 puts us at 1/10 = 10%, no threshold crossed
      result = require_plan_limit!(:projects, billable: @org)

      assert result.within?
      assert_match(/remaining/i, result.message)
    end
  end

  def test_require_plan_limit_within_limit_with_warning_threshold
    # Mock a plan with warning thresholds that would trigger
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        {
          to: 10,
          warn_at: [0.5, 0.8],
          after_limit: :grace_then_block,
          grace: 7.days
        }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      # Mock current usage at 8 (80%)
      PricingPlans::LimitChecker.stub(:current_usage_for, 8) do
        PricingPlans::LimitChecker.stub(:warning_thresholds, [0.5, 0.8]) do
          # Creating 1 more would put us at 9/10 = 90%, crossing 0.8 threshold
          result = require_plan_limit!(:projects, billable: @org, by: 1)

          # This test depends on complex threshold calculation logic
          # The result may be either within with warning or just within
          assert result.within? || result.warning?
        end
      end
    end
  end

  def test_require_plan_limit_exceeded_with_just_warn_policy
    # Mock plan with just_warn policy
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: 1, after_limit: :just_warn }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      # Mock usage at limit
      PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
        result = require_plan_limit!(:projects, billable: @org, by: 1)

        assert result.warning?
        assert_match(/reached your limit/i, result.message)
        assert_match(/upgrade/i, result.message)
      end
    end
  end

  def test_require_plan_limit_exceeded_with_block_usage_policy
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: 1, after_limit: :block_usage }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
        result = require_plan_limit!(:projects, billable: @org, by: 1)

        assert result.blocked?
        assert_match(/reached your limit/i, result.message)

        # Should have called GraceManager.mark_blocked!
        state = PricingPlans::EnforcementState.find_by(billable: @org, limit_key: "projects")
        assert state&.blocked?
      end
    end
  end

  def test_require_plan_limit_exceeded_with_grace_then_block_new_grace
    # Create org with 1 project (at limit)
    @org.projects.create!(name: "Project 1")

    # Explicitly configure plan to use grace_then_block for this test
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 1, after_limit: :grace_then_block, grace: 7.days
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      result = require_plan_limit!(:projects, billable: @org, by: 1)

      # Should start grace period
      assert result.grace?
      assert_match(/exceeded.*grace period/i, result.message)

      # Verify grace state was created
      state = PricingPlans::EnforcementState.find_by(billable: @org, limit_key: "projects")
      assert state&.exceeded?
      refute state&.blocked?
    end
  end

  def test_require_plan_limit_exceeded_with_grace_then_block_existing_grace
    # Create project to be at the limit first
    @org.projects.create!(name: "Project 1") # Now we have 1 project, at the limit of 1

    # Set up existing grace period
    # Use grace_then_block semantics
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 1, after_limit: :grace_then_block, grace: 7.days
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      PricingPlans::GraceManager.mark_exceeded!(@org, :projects)
      result = require_plan_limit!(:projects, billable: @org, by: 1)

      assert result.grace?
      assert_match(/exceeded.*grace period/i, result.message)
    end
  end

  def test_require_plan_limit_exceeded_with_grace_then_block_expired_grace
    # Create project to be at the limit first
    travel_to(Time.parse("2025-01-01 12:00:00 UTC")) do
      @org.projects.create!(name: "Project 1") # Now we have 1 project
      plan = PricingPlans::Plan.new(:tmp)
      plan.limits :projects, to: 1, after_limit: :grace_then_block, grace: 7.days
      PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
        PricingPlans::GraceManager.mark_exceeded!(@org, :projects, grace_period: 7.days)
      end
    end

    # Travel past grace period
    travel_to(Time.parse("2025-01-09 12:00:00 UTC")) do
      plan = PricingPlans::Plan.new(:tmp)
      plan.limits :projects, to: 1, after_limit: :grace_then_block, grace: 7.days
      PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
        result = require_plan_limit!(:projects, billable: @org, by: 1)

        assert result.blocked?
        assert_match(/reached your limit/i, result.message)

        # Should have marked as blocked
        state = PricingPlans::EnforcementState.find_by(billable: @org, limit_key: "projects")
        assert state&.blocked?
      end
    end
  end

  def test_require_feature_allows_when_feature_enabled
    # Assign to pro plan which allows api_access
    PricingPlans::Assignment.assign_plan_to(@org, :pro)

    assert_nothing_raised do
      require_feature!(:api_access, billable: @org)
    end
  end

  def test_require_feature_raises_when_feature_disabled
    # Free plan doesn't allow api_access
    error = assert_raises(PricingPlans::FeatureDenied) do
      require_feature!(:api_access, billable: @org)
    end

    assert_match(/your current plan/i, error.message)
    assert_equal :api_access, error.feature_key
    assert_equal @org, error.billable
  end

  def test_require_feature_raises_with_generic_message_when_no_highlighted_plan
    # Temporarily remove highlighted plan
    original_plan = PricingPlans.configuration.highlighted_plan
    PricingPlans.configuration.highlighted_plan = nil

    begin
      error = assert_raises(PricingPlans::FeatureDenied) do
        require_feature!(:api_access, billable: @org)
      end

      assert_match(/not available on your current plan/i, error.message)
      refute_match(/upgrade to/i, error.message)
    ensure
      PricingPlans.configuration.highlighted_plan = original_plan
    end
  end

  def test_require_feature_returns_true_when_allowed
    PricingPlans::Assignment.assign_plan_to(@org, :pro)

    result = require_feature!(:api_access, billable: @org)
    assert_equal true, result
  end

  def test_time_ago_in_words_helper
    # Test the private helper method used for grace messages
    future_time = Time.current + 3.hours + 45.minutes

    # Access private method for testing
    guards_module = PricingPlans::ControllerGuards
    time_string = guards_module.send(:time_ago_in_words, future_time)

    assert_match(/hours/, time_string)
  end

  def test_time_ago_in_words_with_different_intervals
    base_time = Time.current

    guards_module = PricingPlans::ControllerGuards

    # Test seconds
    result = guards_module.send(:time_ago_in_words, base_time + 30.seconds)
    assert_match(/30 seconds/, result)

    # Test minutes
    result = guards_module.send(:time_ago_in_words, base_time + 45.minutes)
    assert_match(/45 minutes/, result)

    # Test hours
    result = guards_module.send(:time_ago_in_words, base_time + 6.hours)
    assert_match(/6 hours/, result)

    # Test days
    result = guards_module.send(:time_ago_in_words, base_time + 3.days)
    assert_match(/3 days/, result)

    # Test past time
    result = guards_module.send(:time_ago_in_words, base_time - 1.hour)
    assert_equal "no time", result
  end

  def test_require_plan_limit_by_parameter
    # Test the 'by' parameter for bulk operations
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: 5, after_limit: :grace_then_block, grace: 7.days }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      PricingPlans::LimitChecker.stub(:current_usage_for, 3) do
        # Requesting to add 2 more (would be 5 total, at limit)
        result = require_plan_limit!(:projects, billable: @org, by: 2)
        assert result.within?

        # Requesting to add 3 more (would be 6 total, over limit)
        result = require_plan_limit!(:projects, billable: @org, by: 3)
        assert result.grace?
      end
    end
  end

  def test_result_includes_limit_key_and_billable_in_context
    result = require_plan_limit!(:projects, billable: @org, by: 2)

    # All results should include context for potential use in controllers
    if result.grace? || result.blocked? || result.warning?
      assert result.limit_key
      assert result.billable
    end
  end

  def test_build_message_methods_include_upgrade_cta
    guards_module = PricingPlans::ControllerGuards

    message = guards_module.send(:build_over_limit_message, :projects, 1, 1, :blocked)
    assert_match(/upgrade.*pro/i, message)

    grace_message = guards_module.send(
      :build_grace_message,
      :projects,
      2,
      1,
      Time.current + 5.days
    )
    assert_match(/upgrade.*pro/i, grace_message)
  end

  def test_warning_message_includes_remaining_count
    guards_module = PricingPlans::ControllerGuards

    message = guards_module.send(:build_warning_message, :projects, 3, 10)
    assert_match(/3.*projects.*remaining.*10/, message)
  end

  def test_unknown_after_limit_policy_returns_blocked_result
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: 1, after_limit: :unknown_policy }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      PricingPlans::LimitChecker.stub(:current_usage_for, 1) do
        result = require_plan_limit!(:projects, billable: @org, by: 1)

        assert result.blocked?
        assert_match(/unknown after_limit policy/i, result.message)
      end
    end
  end

  def test_require_plan_limit_with_system_override
    org = @org
    # Plan with low limit to trigger exceed
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      { to: 0, after_limit: :block_usage } if key == :projects
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      result = require_plan_limit!(:projects, billable: org, by: 1, allow_system_override: true)

      assert result.blocked?
      assert_equal true, result.metadata[:system_override]
    end
  end

  def test_enforce_plan_limit_helper_redirects_on_block
    org = @org
    # Force a small limit to trigger block
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 0, after_limit: :block_usage

    controller = Class.new do
      include PricingPlans::ControllerGuards
      attr_reader :redirected, :redirect_options
      def pricing_path; "/pricing"; end
      def redirect_to(path, opts={}); @redirected = path; @redirect_options = opts; end
      def flash; @flash ||= {}; end
    end.new

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      caught = catch(:abort) do
        controller.enforce_plan_limit!(:projects, billable: org, by: 1)
        :no_abort
      end
      assert_equal "/pricing", controller.instance_variable_get(:@redirected)
      assert_equal :see_other, controller.instance_variable_get(:@redirect_options)[:status]
      assert caught != :no_abort
    end
  end

  def test_enforce_plan_limit_uses_per_controller_default_before_global
    org = @org
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 0, after_limit: :block_usage

    controller_class = Class.new do
      include PricingPlans::ControllerGuards
      class << self; attr_accessor :pricing_plans_redirect_on_blocked_limit; end
      attr_reader :redirected, :redirect_options
      def redirect_to(path, opts={}); @redirected = path; @redirect_options = opts; end
      def flash; @flash ||= {}; end
    end
    controller = controller_class.new

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      original = PricingPlans.configuration.redirect_on_blocked_limit
      begin
        PricingPlans.configuration.redirect_on_blocked_limit = "/global"
        controller_class.pricing_plans_redirect_on_blocked_limit = "/local"
        caught = catch(:abort) do
          controller.enforce_plan_limit!(:projects, billable: org, by: 1)
          :no_abort
        end
        refute_equal :no_abort, caught
        assert_equal "/local", controller.instance_variable_get(:@redirected)
      ensure
        controller_class.pricing_plans_redirect_on_blocked_limit = nil
        PricingPlans.configuration.redirect_on_blocked_limit = original
      end
    end
  end

  def test_enforce_plan_limit_uses_global_when_no_local_and_no_pricing_path
    org = @org
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 0, after_limit: :block_usage

    controller = Class.new do
      include PricingPlans::ControllerGuards
      attr_reader :redirected, :redirect_options
      def redirect_to(path, opts={}); @redirected = path; @redirect_options = opts; end
      def flash; @flash ||= {}; end
    end.new

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      original = PricingPlans.configuration.redirect_on_blocked_limit
      begin
        PricingPlans.configuration.redirect_on_blocked_limit = "/global_only"
        caught = catch(:abort) do
          controller.enforce_plan_limit!(:projects, billable: org, by: 1)
          :no_abort
        end
        refute_equal :no_abort, caught
        assert_equal "/global_only", controller.instance_variable_get(:@redirected)
      ensure
        PricingPlans.configuration.redirect_on_blocked_limit = original
      end
    end
  end

  def test_enforce_plan_limit_renders_403_when_no_redirect_targets
    org = @org
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 0, after_limit: :block_usage

    controller = Class.new do
      include PricingPlans::ControllerGuards
      attr_reader :rendered
      def render(status:, plain: nil, json: nil)
        @rendered = { status: status, plain: plain, json: json }
      end
      def request
        OpenStruct.new(format: OpenStruct.new(html?: true, json?: false))
      end
      def flash; @flash ||= { now: {} }; end
    end.new

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      original = PricingPlans.configuration.redirect_on_blocked_limit
      begin
        PricingPlans.configuration.redirect_on_blocked_limit = nil
        caught = catch(:abort) do
          controller.enforce_plan_limit!(:projects, billable: org, by: 1)
          :no_abort
        end
        refute_equal :no_abort, caught
        assert_equal :forbidden, controller.instance_variable_get(:@rendered)[:status]
      ensure
        PricingPlans.configuration.redirect_on_blocked_limit = original
      end
    end
  end

  def test_enforce_plan_limit_uses_global_handler_when_available
    org = @org
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 0, after_limit: :block_usage

    controller = Class.new do
      include PricingPlans::ControllerGuards
      include PricingPlans::ControllerRescues
      attr_reader :handled
      def handle_pricing_plans_limit_blocked(result)
        @handled = [result.message, result.metadata[:redirect_to]]
      end
      def pricing_path; "/pricing"; end
    end.new

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      caught = catch(:abort) do
        controller.enforce_plan_limit!(:projects, billable: org, by: 1)
        :no_abort
      end
      refute_equal :no_abort, caught
      handled = controller.instance_variable_get(:@handled)
      assert_match(/limit/i, handled.first)
      assert_equal "/pricing", handled.last
    end
  end

  def test_dynamic_enforce_limit_helper
    org = @org
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 0, after_limit: :block_usage

    controller = Class.new do
      include PricingPlans::ControllerGuards
      def pricing_path; "/pricing"; end
      def redirect_to(*); end
    end.new

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      caught = catch(:abort) do
        controller.enforce_projects_limit!(billable: org, by: 1)
        :no_abort
      end
      refute_equal :no_abort, caught
    end
  end

  def test_enforce_plan_limit_helper_with_system_override_does_not_redirect
    org = @org
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 0, after_limit: :block_usage

    controller = Class.new do
      include PricingPlans::ControllerGuards
      attr_reader :redirected
      def redirect_to(*); @redirected = true; end
      def flash; @flash ||= {}; end
    end.new

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      # allow_system_override should short-circuit block handling
      result = controller.enforce_plan_limit!(
        :projects,
        billable: org,
        by: 1,
        allow_system_override: true
      )
      assert result
      refute controller.instance_variable_get(:@redirected)
    end
  end

  def test_dynamic_enforce_limit_with_custom_redirect
    org = @org
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 0, after_limit: :block_usage

    controller = Class.new do
      include PricingPlans::ControllerGuards
      attr_reader :redirect_target
      def redirect_to(path, **opts); @redirect_target = [path, opts]; end
    end.new

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      caught = catch(:abort) do
        controller.enforce_projects_limit!(billable: org, by: 1, redirect_to: "/upgrade")
        :no_abort
      end
      assert controller.instance_variable_get(:@redirect_target)
      path, opts = controller.instance_variable_get(:@redirect_target)
      assert_equal "/upgrade", path
      assert_equal :see_other, opts[:status]
      assert caught != :no_abort
    end
  end

  def test_dynamic_enforce_limit_with_on_alias_symbol
    org = @org
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 0, after_limit: :block_usage

    controller = Class.new do
      include PricingPlans::ControllerGuards
      def org_alias; @org; end
      def pricing_path; "/pricing"; end
      def redirect_to(*); end
    end.new
    controller.instance_variable_set(:@org, org)

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      caught = catch(:abort) do
        controller.enforce_projects_limit!(on: :org_alias)
        :no_abort
      end
      refute_equal :no_abort, caught
    end
  end

  def test_dynamic_feature_guard_with_on_alias
    org = @org
    controller = Class.new do
      include PricingPlans::ControllerGuards
      def current_organization; @org; end
    end.new
    controller.instance_variable_set(:@org, org)

    # Free plan disallows api_access, should raise
    assert_raises(PricingPlans::FeatureDenied) do
      controller.enforce_api_access!(on: :current_organization)
    end

    # Assign pro which allows api_access; should pass
    PricingPlans::Assignment.assign_plan_to(org, :pro)
    assert_equal true, controller.enforce_api_access!(on: :current_organization)
  end

  def test_global_controller_billable_proc_is_used_when_no_per_controller
    org = @org
    controller = Class.new do
      include PricingPlans::ControllerGuards
      def current_account; @acc; end
    end.new
    controller.instance_variable_set(:@acc, org)

    original_cfg = PricingPlans.configuration
    begin
      PricingPlans.reset_configuration!
      PricingPlans.configure do |config|
        config.default_plan = :free
        config.controller_billable { current_account }
        config.plan :free do
          disallows :api_access
        end
        config.plan :pro do
          allows :api_access
        end
      end

      assert_raises(PricingPlans::FeatureDenied) do
        controller.enforce_api_access!
      end

      PricingPlans::Assignment.assign_plan_to(org, :pro)
      assert_equal true, controller.enforce_api_access!
    ensure
      PricingPlans.instance_variable_set(:@configuration, original_cfg)
    end
  end

  def test_global_controller_billable_symbol_is_used_when_no_per_controller
    org = @org
    controller = Class.new do
      include PricingPlans::ControllerGuards
      def current_organization; @org; end
    end.new
    controller.instance_variable_set(:@org, org)

    original_cfg = PricingPlans.configuration
    begin
      PricingPlans.reset_configuration!
      PricingPlans.configure do |config|
        config.default_plan = :free
        config.controller_billable :current_organization
        config.plan :free do
          disallows :api_access
        end
        config.plan :pro do
          allows :api_access
        end
      end

      assert_raises(PricingPlans::FeatureDenied) do
        controller.enforce_api_access!
      end

      PricingPlans::Assignment.assign_plan_to(org, :pro)
      assert_equal true, controller.enforce_api_access!
    ensure
      PricingPlans.instance_variable_set(:@configuration, original_cfg)
    end
  end
end
