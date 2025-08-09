# frozen_string_literal: true

require "test_helper"
require "securerandom"

class LimitableTest < ActiveSupport::TestCase
  def setup
    super
  end

  def test_limited_by_configures_persistent_limit
    project = Project.new(name: "Test", organization: create_organization)
    assert Project.pricing_plans_limits.key?(:projects)
    assert_equal :organization, Project.pricing_plans_limits[:projects][:billable_method]
    assert_nil Project.pricing_plans_limits[:projects][:per]
  end

  def test_limited_by_configures_per_period_limit
    custom_model = CustomModel.new(name: "Test", organization: create_organization)
    assert CustomModel.pricing_plans_limits.key?(:custom_models)
    assert_equal :organization, CustomModel.pricing_plans_limits[:custom_models][:billable_method]
    assert_equal :month, CustomModel.pricing_plans_limits[:custom_models][:per]
  end

  def test_registers_counter_for_persistent_limits
    counter = PricingPlans::LimitableRegistry.counter_for(:projects)
    assert counter, "Expected counter to be registered for :projects"

    org = create_organization
    org.projects.create!(name: "Test 1")
    org.projects.create!(name: "Test 2")

    count = counter.call(org)
    assert_equal 2, count
  end

  def test_does_not_register_counter_for_per_period_limits
    counter = PricingPlans::LimitableRegistry.counter_for(:custom_models)
    assert_nil counter, "Expected no counter for per-period limits"
  end

  def test_count_for_billable_counts_associated_records
    org = create_organization
    Project.create!(name: "Project 1", organization: org)
    Project.create!(name: "Project 2", organization: org)

    other_org = create_organization
    Project.create!(name: "Other Project", organization: other_org)

    count = Project.count_for_billable(org, :organization)
    assert_equal 2, count

    other_count = Project.count_for_billable(other_org, :organization)
    assert_equal 1, other_count
  end

  def test_validation_prevents_creation_when_over_persistent_limit
    org = create_organization
    org.projects.create!(name: "Project 1")

    PricingPlans::GraceManager.stub(:should_block?, true) do
      project = org.projects.build(name: "Project 2")
      refute project.valid?, "Expected validation to fail when over limit and should block"
      assert project.errors[:base].any?, "Expected base error for limit exceeded"
    end
  end

  def test_custom_error_message_on_over_limit
    model_name = "CustomProjects_#{SecureRandom.hex(4)}"
    Object.const_set(model_name, Class.new(ActiveRecord::Base))
    klass = Object.const_get(model_name).class_eval do
      self.table_name = "projects"
      belongs_to :organization
      include PricingPlans::Limitable
      limited_by_pricing_plans :projects, billable: :organization, error_after_limit: "Too many projects!"
      self
    end

    org = create_organization
    org.projects.create!(name: "Project 1")

    PricingPlans::GraceManager.stub(:should_block?, true) do
      record = klass.new(name: "Project 2", organization: org)
      refute record.valid?
      assert_includes record.errors.full_messages.join, "Too many projects!"
    end
  ensure
    Object.send(:remove_const, model_name.to_sym) if Object.const_defined?(model_name.to_sym)
  end

  def test_validation_allows_creation_when_within_limit
    org = create_organization
    project = org.projects.build(name: "Project 1")
    assert project.valid?, "Expected validation to pass when within limit"
  end

  def test_validation_skips_when_no_plan_configured
    org = Organization.create!(name: "Test Org")
    PricingPlans::PlanResolver.stub(:effective_plan_for, nil) do
      project = org.projects.build(name: "Test Project")
      assert project.valid?, "Expected validation to pass when no plan configured"
    end
  end

  def test_validation_skips_when_unlimited
    org = create_organization
    unlimited_plan = OpenStruct.new
    unlimited_plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: :unlimited }
      else
        nil
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, unlimited_plan) do
      project1 = org.projects.create!(name: "Project 1")
      project2 = org.projects.create!(name: "Project 2")
      project3 = org.projects.create!(name: "Project 3")

      assert project1.persisted?
      assert project2.persisted?
      assert project3.persisted?
    end
  end

  def test_per_period_counter_incrementation_on_create
    org = create_organization
    PricingPlans::Assignment.assign_plan_to(org, :pro)

    travel_to(Time.parse("2025-01-15 12:00:00 UTC")) do
      custom_model = org.custom_models.create!(name: "Model 1")
      usage = PricingPlans::Usage.find_by(
        billable: org,
        limit_key: "custom_models"
      )
      assert usage, "Expected usage record to be created"
      assert_equal 1, usage.used
      assert_in_delta Time.current, usage.last_used_at, 1.second
    end
  end

  def test_per_period_counter_handles_race_conditions
    org = create_organization
    PricingPlans::Assignment.assign_plan_to(org, :pro)

    travel_to(Time.parse("2025-01-15 12:00:00 UTC")) do
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :custom_models)

      existing_usage = PricingPlans::Usage.create!(
        billable: org,
        limit_key: "custom_models",
        period_start: period_start,
        period_end: period_end,
        used: 1
      )

      custom_model = org.custom_models.create!(name: "Model 1")
      existing_usage.reload
      assert_equal 2, existing_usage.used
    end
  end

  def test_persistent_counter_does_not_decrement_on_destroy
    org = create_organization
    project1 = org.projects.create!(name: "Project 1")
    project2 = org.projects.create!(name: "Project 2")

    counter = PricingPlans::LimitableRegistry.counter_for(:projects)
    assert_equal 2, counter.call(org)

    project1.destroy!
    assert_equal 1, counter.call(org)
  end

  def test_validation_method_names_are_unique_per_limit_key
    assert Project.method_defined?(:check_limit_on_create_projects)
    assert CustomModel.method_defined?(:check_limit_on_create_custom_models)
    refute_equal Project.instance_method(:check_limit_on_create_projects),
                CustomModel.instance_method(:check_limit_on_create_custom_models)
  end

  def test_class_attribute_inheritance
    refute_equal Project.pricing_plans_limits.object_id,
                CustomModel.pricing_plans_limits.object_id

    assert Project.pricing_plans_limits.key?(:projects)
    assert CustomModel.pricing_plans_limits.key?(:custom_models)

    refute Project.pricing_plans_limits.key?(:custom_models)
    refute CustomModel.pricing_plans_limits.key?(:projects)
  end

  def test_after_create_callback_is_registered
    assert Project._create_callbacks.any? { |cb| cb.filter.to_s.include?("increment_per_period_counters") }
    assert CustomModel._create_callbacks.any? { |cb| cb.filter.to_s.include?("increment_per_period_counters") }
  end

  def test_after_destroy_callback_is_registered
    assert Project._destroy_callbacks.any? { |cb| cb.filter.to_s.include?("decrement_persistent_counters") }
    assert CustomModel._destroy_callbacks.any? { |cb| cb.filter.to_s.include?("decrement_persistent_counters") }
  end

  def test_billable_method_self_option
    test_class = Class.new(ActiveRecord::Base) do
      self.table_name = "organizations"
      include PricingPlans::Limitable
      limited_by_pricing_plans :self_limit, billable: :self
    end

    test_instance = test_class.new(name: "Test")
    assert_equal :self, test_class.pricing_plans_limits[:self_limit][:billable_method]
  end

  def test_multiple_limits_on_same_model
    test_class = Class.new(ActiveRecord::Base) do
      self.table_name = "projects"
      include PricingPlans::Limitable
      limited_by_pricing_plans :first_limit, billable: :organization
      limited_by_pricing_plans :second_limit, billable: :organization, per: :week
    end

    limits = test_class.pricing_plans_limits
    assert limits.key?(:first_limit)
    assert limits.key?(:second_limit)
    assert_nil limits[:first_limit][:per]
    assert_equal :week, limits[:second_limit][:per]
  end
end
