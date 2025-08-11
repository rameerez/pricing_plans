# frozen_string_literal: true

require "test_helper"

class LimitCheckerMoreTest < ActiveSupport::TestCase
  def setup
    super
    @org = create_organization
  end

  def test_remaining_returns_unlimited_when_no_limit_configured
    # For an unknown limit key, remaining should be :unlimited
    assert_equal :unlimited, PricingPlans::LimitChecker.plan_limit_remaining(@org, :unknown_limit)
    assert PricingPlans::LimitChecker.within_limit?(@org, :unknown_limit)
  end

  def test_after_limit_action_default_when_no_limit_configured
    # Default action when no limit is configured should be :block_usage per current implementation
    assert_equal :block_usage, PricingPlans::LimitChecker.after_limit_action(@org, :unknown_limit)
  end

  def test_percent_used_handles_unlimited_and_zero_limits
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      case key
      when :unlimited_key
        { to: :unlimited }
      when :zero_key
        { to: 0 }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      assert_equal 0.0, PricingPlans::LimitChecker.plan_limit_percent_used(@org, :unlimited_key)
      assert_equal 0.0, PricingPlans::LimitChecker.plan_limit_percent_used(@org, :zero_key)
    end
  end

  def test_should_warn_returns_highest_crossed_threshold_only_once
    org = @org
    # Prepare a plan with thresholds
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      { to: 10, warn_at: [0.5, 0.8] } if key == :projects
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      # Simulate usage at 9/10 = 90%
      PricingPlans::LimitChecker.stub(:current_usage_for, 9) do
        threshold = PricingPlans::LimitChecker.should_warn?(org, :projects)
        assert_equal 0.8, threshold
      end

      # Create an enforcement state with last_warning_threshold = 0.8
      state = PricingPlans::EnforcementState.create!(billable: org, limit_key: "projects", last_warning_threshold: 0.8)

      # Now at 6/10 = 60%, lower than last threshold → should be nil
      PricingPlans::LimitChecker.stub(:current_usage_for, 6) do
        assert_nil PricingPlans::LimitChecker.should_warn?(org, :projects)
      end

      # At 10/10 = 100%, higher than last threshold → still returns 0.8 (highest defined)
      PricingPlans::LimitChecker.stub(:current_usage_for, 10) do
        assert_nil PricingPlans::LimitChecker.should_warn?(org, :projects), "no new higher threshold to emit"
      end
    end
  end

  def test_persistent_count_scope_via_plan
    org = @org
    # Create two projects; we'll scope count to 1 via a custom relation
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    org.projects.create!(name: "A")
    org.projects.create!(name: "B")

    # Stub plan to include count_scope that limits to 1 record
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: 1, after_limit: :grace_then_block, count_scope: ->(rel) { rel.limit(1) } }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      # current_usage should respect scoped relation (1)
      assert_equal 1, PricingPlans::LimitChecker.current_usage_for(org, :projects)
      # within_limit? for by:1 should be false (at limit)
      refute PricingPlans::LimitChecker.within_limit?(org, :projects, by: 1)
    end
  end

  def test_persistent_count_scope_symbol_scope
    org = @org
    # Define a scope on Project for testing
    Project.class_eval do
      scope :with_name_a, -> { where(name: 'A') }
    end
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    org.projects.create!(name: 'A')
    org.projects.create!(name: 'B')

    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      { to: 1, count_scope: :with_name_a } if key == :projects
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      assert_equal 1, PricingPlans::LimitChecker.current_usage_for(org, :projects)
    end
  end

  def test_persistent_count_scope_hash_where
    org = @org
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    org.projects.create!(name: 'A')
    org.projects.create!(name: 'B')

    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      { to: 1, count_scope: { name: 'A' } } if key == :projects
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      assert_equal 1, PricingPlans::LimitChecker.current_usage_for(org, :projects)
    end
  end

  def test_persistent_count_scope_array_chain
    org = @org
    Project.class_eval do
      scope :named_a, -> { where(name: 'A') }
    end
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    org.projects.create!(name: 'A')
    org.projects.create!(name: 'B')

    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      { to: 1, count_scope: [:named_a, { name: 'A' }] } if key == :projects
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      assert_equal 1, PricingPlans::LimitChecker.current_usage_for(org, :projects)
    end
  end

  def test_macro_count_scope_fallback_when_no_plan_scope
    org = @org
    # Define a temporary model constant to test macro-level scope
    klass_name = "CountScopeMacro_#{SecureRandom.hex(4)}"
    Object.const_set(klass_name, Class.new(ActiveRecord::Base))
    klass = Object.const_get(klass_name).class_eval do
      self.table_name = 'projects'
      belongs_to :organization
      include PricingPlans::Limitable
      limited_by_pricing_plans :projects, billable: :organization, count_scope: { name: 'A' }
      self
    end

    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    org.projects.create!(name: 'A')
    org.projects.create!(name: 'B')

    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      { to: 10 } if key == :projects
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      assert_equal 1, PricingPlans::LimitChecker.current_usage_for(org, :projects)
    end
  ensure
    Object.send(:remove_const, klass_name.to_sym) if Object.const_defined?(klass_name.to_sym)
  end

  def test_plan_count_scope_precedence_over_macro
    org = @org
    # Macro wants name A; plan will override to name B
    Project.class_eval do
      scope :named_a, -> { where(name: 'A') }
      scope :named_b, -> { where(name: 'B') }
    end
    Project.send(:limited_by_pricing_plans, :projects, billable: :organization, count_scope: :named_a)

    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    org.projects.create!(name: 'A')
    org.projects.create!(name: 'B')

    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      { to: 1, count_scope: :named_b } if key == :projects
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      assert_equal 1, PricingPlans::LimitChecker.current_usage_for(org, :projects)
    end
  end

  def test_persistent_count_scope_proc_with_billable_param
    org1 = create_organization
    org2 = create_organization
    PricingPlans::Assignment.assign_plan_to(org1, :enterprise)
    PricingPlans::Assignment.assign_plan_to(org2, :enterprise)

    # Records for both orgs
    org1.projects.create!(name: 'A')
    org1.projects.create!(name: 'B')
    org2.projects.create!(name: 'A')

    # Plan-level scope that uses both relation and billable
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: 10, count_scope: ->(rel, billable) { rel.where(organization_id: billable.id).where(name: 'A') } }
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      # Only org1's 'A' should count for org1
      assert_equal 1, PricingPlans::LimitChecker.current_usage_for(org1, :projects)
      # Only org2's 'A' should count for org2
      assert_equal 1, PricingPlans::LimitChecker.current_usage_for(org2, :projects)
    end
  end

  def test_count_scope_disallowed_on_per_period
    error = assert_raises(PricingPlans::ConfigurationError) do
      # Force plan validation through Plan instance to trigger check
      p = PricingPlans::Plan.new(:tmp)
      p.limits :custom_models, to: 1, per: :month, count_scope: { name: 'A' }
      p.validate!
    end
    assert_match(/cannot set count_scope for per-period/, error.message)
  end

  def test_job_guards_within_limit_yields
    org = @org
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) { |key| { to: 1 } if key == :projects }
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      yielded = false
      result = PricingPlans::JobGuards.with_plan_limit(:projects, billable: org, by: 1) { yielded = true }
      assert yielded
      assert result.within?
    end
  end

  def test_job_guards_blocked_without_override_does_not_yield
    org = @org
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) { |key| { to: 0, after_limit: :block_usage } if key == :projects }
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      yielded = false
      result = PricingPlans::JobGuards.with_plan_limit(:projects, billable: org, by: 1) { yielded = true }
      refute yielded
      assert result.blocked?
    end
  end

  def test_job_guards_blocked_with_system_override_yields
    org = @org
    plan = OpenStruct.new
    plan.define_singleton_method(:limit_for) { |key| { to: 0, after_limit: :block_usage } if key == :projects }
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      yielded = false
      result = PricingPlans::JobGuards.with_plan_limit(:projects, billable: org, by: 1, allow_system_override: true) { yielded = true }
      assert yielded
      assert result.blocked?
      assert_equal true, result.metadata[:system_override]
    end
  end
end
