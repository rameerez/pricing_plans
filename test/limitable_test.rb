# frozen_string_literal: true

require "test_helper"
require "securerandom"

class LimitableTest < ActiveSupport::TestCase
  def setup
    super  # This calls the test helper setup which configures plans
    # Note: Not clearing the registry here as some tests check if counters are registered
  end

  def test_limited_by_configures_persistent_limit
    # This is tested indirectly through the Project model which includes Limitable
    # and calls limited_by :projects, billable: :organization

    project = Project.new(name: "Test", organization: create_organization)

    # The pricing_plans_limits should be configured
    assert Project.pricing_plans_limits.key?(:projects)
    assert_equal :organization, Project.pricing_plans_limits[:projects][:billable_method]
    assert_nil Project.pricing_plans_limits[:projects][:per]
  end

  def test_limited_by_configures_per_period_limit
    # This is tested indirectly through the CustomModel model
    custom_model = CustomModel.new(name: "Test", organization: create_organization)

    assert CustomModel.pricing_plans_limits.key?(:custom_models)
    assert_equal :organization, CustomModel.pricing_plans_limits[:custom_models][:billable_method]
    assert_equal :month, CustomModel.pricing_plans_limits[:custom_models][:per]
  end

  def test_registers_counter_for_persistent_limits
    # Verify that Project registered a counter
    counter = PricingPlans::LimitableRegistry.counter_for(:projects)
    assert counter, "Expected counter to be registered for :projects"

    org = create_organization
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    org.projects.create!(name: "Test 1")
    org.projects.create!(name: "Test 2")

    count = counter.call(org)
    assert_equal 2, count
  end

  def test_does_not_register_counter_for_per_period_limits
    # CustomModel uses per: :month, so no counter should be registered
    counter = PricingPlans::LimitableRegistry.counter_for(:custom_models)
    assert_nil counter, "Expected no counter for per-period limits"
  end

  def test_count_for_billable_counts_associated_records
    org = create_organization
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    Project.create!(name: "Project 1", organization: org)
    Project.create!(name: "Project 2", organization: org)

    # Create projects for different org to ensure isolation
    other_org = create_organization
    PricingPlans::Assignment.assign_plan_to(other_org, :enterprise)
    Project.create!(name: "Other Project", organization: other_org)

    count = Project.count_for_billable(org, :organization)
    assert_equal 2, count

    other_count = Project.count_for_billable(other_org, :organization)
    assert_equal 1, other_count
  end

  def test_validation_prevents_creation_when_over_persistent_limit
    org = create_organization

    # Create project up to the limit (1 for free plan)
    org.projects.create!(name: "Project 1")

    # Mock GraceManager to simulate immediate blocking (not grace period)
    PricingPlans::GraceManager.stub(:should_block?, true) do
      project = org.projects.build(name: "Project 2")

      refute project.valid?, "Expected validation to fail when over limit and should block"
      assert project.errors[:base].any?, "Expected base error for limit exceeded"
    end
  end

  def test_custom_error_message_on_over_limit
    # Define a temporary model with custom error message, with a constant name to please AR reflection
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
  end

  def test_validation_allows_creation_when_within_limit
    org = create_organization

    # Free plan allows 1 project, so first creation should work
    project = org.projects.build(name: "Project 1")

    assert project.valid?, "Expected validation to pass when within limit"
  end

  def test_validation_skips_when_no_plan_configured
    # Create an organization without a configured plan
    org = Organization.create!(name: "Test Org")

    # Mock PlanResolver to return nil
    PricingPlans::PlanResolver.stub(:effective_plan_for, nil) do
      project = org.projects.build(name: "Test Project")
      assert project.valid?, "Expected validation to pass when no plan configured"
    end
  end

  def test_validation_skips_when_unlimited
    org = create_organization

    # Mock the plan to return unlimited for projects
    unlimited_plan = OpenStruct.new
    unlimited_plan.define_singleton_method(:limit_for) do |key|
      if key == :projects
        { to: :unlimited }
      else
        nil
      end
    end

    PricingPlans::PlanResolver.stub(:effective_plan_for, unlimited_plan) do
      # Should be able to create many projects when unlimited
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
    PricingPlans::Assignment.assign_plan_to(org, :pro)  # Pro plan has custom_models limit

    # Create custom model should increment usage counter
    travel_to(Time.parse("2025-01-15 12:00:00 UTC")) do
      custom_model = org.custom_models.create!(name: "Model 1")

      # Find the usage record - let the system calculate the period
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
      # Get the actual period that will be calculated
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :custom_models)

      # Simulate race condition by creating usage record first
      existing_usage = PricingPlans::Usage.create!(
        billable: org,
        limit_key: "custom_models",
        period_start: period_start,
        period_end: period_end,
        used: 1
      )

      # Create model should increment existing record
      custom_model = org.custom_models.create!(name: "Model 1")

      existing_usage.reload
      assert_equal 2, existing_usage.used
    end
  end

  def test_persistent_counter_does_not_decrement_on_destroy
    # This is by design - persistent counters are computed live
    org = create_organization
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)

    project1 = org.projects.create!(name: "Project 1")
    project2 = org.projects.create!(name: "Project 2")

    counter = PricingPlans::LimitableRegistry.counter_for(:projects)
    assert_equal 2, counter.call(org)

    project1.destroy!

    # Count should reflect the live state (1 remaining project)
    assert_equal 1, counter.call(org)
  end

  def test_validation_method_names_are_unique_per_limit_key
    # The validation methods should have unique names to avoid conflicts
    # Projects use :projects limit
    assert Project.method_defined?(:check_limit_on_create_projects)

    # CustomModels use :custom_models limit
    assert CustomModel.method_defined?(:check_limit_on_create_custom_models)

    # Methods should be different
    refute_equal Project.instance_method(:check_limit_on_create_projects),
                CustomModel.instance_method(:check_limit_on_create_custom_models)
  end

  def test_class_attribute_inheritance
    # Each model should have its own pricing_plans_limits
    refute_equal Project.pricing_plans_limits.object_id,
                CustomModel.pricing_plans_limits.object_id

    assert Project.pricing_plans_limits.key?(:projects)
    assert CustomModel.pricing_plans_limits.key?(:custom_models)

    refute Project.pricing_plans_limits.key?(:custom_models)
    refute CustomModel.pricing_plans_limits.key?(:projects)
  end

  def test_after_create_callback_is_registered
    # Verify callbacks are set up
    assert Project._create_callbacks.any? { |cb|
      cb.filter.to_s.include?("increment_per_period_counters")
    }

    assert CustomModel._create_callbacks.any? { |cb|
      cb.filter.to_s.include?("increment_per_period_counters")
    }
  end

  def test_after_destroy_callback_is_registered
    assert Project._destroy_callbacks.any? { |cb|
      cb.filter.to_s.include?("decrement_persistent_counters")
    }

    assert CustomModel._destroy_callbacks.any? { |cb|
      cb.filter.to_s.include?("decrement_persistent_counters")
    }
  end

  def test_billable_method_self_option
    # Test a theoretical model that limits itself
    test_class = Class.new(ActiveRecord::Base) do
      self.table_name = "organizations"  # Reuse existing table for test
      include PricingPlans::Limitable
      limited_by_pricing_plans :self_limit, billable: :self
    end

    test_instance = test_class.new(name: "Test")

    assert_equal :self, test_class.pricing_plans_limits[:self_limit][:billable_method]
  end

  def test_multiple_limits_on_same_model
    # Test a model with multiple limits
    test_class = Class.new(ActiveRecord::Base) do
      self.table_name = "projects"  # Reuse existing table
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

  def test_infers_limit_key_when_omitted_and_billable_from_config
    test_class = Class.new(ActiveRecord::Base) do
      self.table_name = "projects"
      belongs_to :organization
      include PricingPlans::Limitable
      limited_by_pricing_plans
    end

    limits = test_class.pricing_plans_limits
    assert limits.key?(:projects)
    assert_equal :organization, limits[:projects][:billable_method]
    assert_nil limits[:projects][:per]
  end

  def test_infers_billable_from_common_conventions_when_configured_missing
    # Temporarily set an unassociated billable_class so it won't match
    original = PricingPlans.configuration.billable_class
    PricingPlans.configuration.billable_class = "Workspace"

    begin
    test_class = Class.new(ActiveRecord::Base) do
        self.table_name = "projects"
        belongs_to :account, class_name: "Organization", foreign_key: "organization_id"
        include PricingPlans::Limitable
        limited_by_pricing_plans :projects
      end

      limits = test_class.pricing_plans_limits
      assert_equal :account, limits[:projects][:billable_method]
    ensure
      PricingPlans.configuration.billable_class = original
    end
  end

  def test_fallback_to_self_when_no_association_found
    test_class = Class.new(ActiveRecord::Base) do
      self.table_name = "organizations"
      include PricingPlans::Limitable
      limited_by_pricing_plans :self_limit
    end

    limits = test_class.pricing_plans_limits
    assert_equal :self, limits[:self_limit][:billable_method]
  end

  def test_per_period_with_inference
    test_class = Class.new(ActiveRecord::Base) do
      self.table_name = "projects"
      belongs_to :organization
      include PricingPlans::Limitable
      limited_by_pricing_plans :custom_models, per: :month
    end

    limits = test_class.pricing_plans_limits
    assert_equal :month, limits[:custom_models][:per]
    assert_equal :organization, limits[:custom_models][:billable_method]
  end

  def test_registers_counter_for_inferred_persistent_limit
    klass_name = "PricingPlansTestModel_#{SecureRandom.hex(4)}"
    Object.const_set(klass_name, Class.new(ActiveRecord::Base))
    test_class = Object.const_get(klass_name).class_eval do
      self.table_name = "projects"
      belongs_to :organization
      include PricingPlans::Limitable
      limited_by_pricing_plans # infers :projects
      self
    end

    org = create_organization
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    # Use real Project records to exercise counter callable
    Project.create!(name: "P1", organization: org)
    Project.create!(name: "P2", organization: org)

    counter = PricingPlans::LimitableRegistry.counter_for(:projects)
    assert counter, "Expected counter to be registered for :projects"
    assert_equal 2, counter.call(org)
  end
end
