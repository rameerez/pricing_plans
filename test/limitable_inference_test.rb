# frozen_string_literal: true

require "test_helper"

class LimitableInferenceTest < ActiveSupport::TestCase
  def test_infers_limit_key_when_omitted
    test_class = Class.new(ActiveRecord::Base) do
      self.table_name = "projects"
      belongs_to :organization
      include PricingPlans::Limitable
      limited_by_pricing_plans # infer :projects and billable :organization
    end

    limits = test_class.pricing_plans_limits
    assert limits.key?(:projects)
    assert_equal :organization, limits[:projects][:billable_method]
    assert_nil limits[:projects][:per]
  end

  def test_falls_back_to_self_when_no_association_found
    test_class = Class.new(ActiveRecord::Base) do
      self.table_name = "organizations"
      include PricingPlans::Limitable
      limited_by_pricing_plans :own_records
    end

    limits = test_class.pricing_plans_limits
    assert_equal :self, limits[:own_records][:billable_method]
  end

  def test_on_alias_for_billable_keyword
    test_class = Class.new(ActiveRecord::Base) do
      self.table_name = "projects"
      belongs_to :organization
      include PricingPlans::Limitable
      limited_by_pricing_plans :projects, on: :organization
    end

    limits = test_class.pricing_plans_limits
    assert_equal :organization, limits[:projects][:billable_method]
  end

  def test_billable_declares_association_limits_via_has_many_option
    klass_name = "OrgWithLimitedAssoc_#{SecureRandom.hex(4)}"
    Object.const_set(klass_name, Class.new(ActiveRecord::Base))
    org_class = Object.const_get(klass_name).class_eval do
      self.table_name = "organizations"
      include PricingPlans::Billable
      has_many :projects, limited_by_pricing_plans: { error_after_limit: "Too many projects!" }
      self
    end

    # The child model should have received Limitable configuration for :projects
    assert Project.pricing_plans_limits.key?(:projects)
    assert_equal :organization, Project.pricing_plans_limits[:projects][:billable_method]
    assert_equal "Too many projects!", Project.pricing_plans_limits[:projects][:error_after_limit]

    # The billable should expose sugar methods
    inst = org_class.new
    assert_respond_to inst, :projects_within_plan_limits?
    assert_respond_to inst, :projects_remaining
  ensure
    Object.send(:remove_const, klass_name.to_sym) if Object.const_defined?(klass_name.to_sym)
  end

  def test_has_many_limited_registers_when_child_class_defined_later
    billable_const = "OrgWithPending_#{SecureRandom.hex(4)}"
    child_const = "LaterProject_#{SecureRandom.hex(4)}"
    Object.const_set(billable_const, Class.new(ActiveRecord::Base))
    org_class = Object.const_get(billable_const).class_eval do
      self.table_name = "organizations"
      include PricingPlans::Billable
      has_many :later_projects,
        class_name: child_const,
        foreign_key: "organization_id",
        limited_by_pricing_plans: { per: :month, error_after_limit: "Monthly cap" }
      self
    end

    # Child not defined yet, so pending registry should have captured it
    assert PricingPlans::AssociationLimitRegistry.pending.any?

    # Define the child class mapping to existing projects table
    Object.const_set(child_const, Class.new(ActiveRecord::Base))
    Object.const_get(child_const).class_eval do
      self.table_name = "projects"
      belongs_to :organization
    end

    # Flush pending to complete wiring
    PricingPlans::AssociationLimitRegistry.flush_pending!

    child_klass = Object.const_get(child_const)
    limits = child_klass.pricing_plans_limits
    assert limits.key?(:later_projects)
    assert_equal :organization, limits[:later_projects][:billable_method]
    assert_equal :month, limits[:later_projects][:per]
    assert_equal "Monthly cap", limits[:later_projects][:error_after_limit]
  ensure
    Object.send(:remove_const, billable_const.to_sym) if Object.const_defined?(billable_const.to_sym)
    Object.send(:remove_const, child_const.to_sym) if Object.const_defined?(child_const.to_sym)
  end

  def test_registers_counter_only_for_persistent_caps
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "projects"
      belongs_to :organization
      include PricingPlans::Limitable
      limited_by_pricing_plans :projects
      limited_by_pricing_plans :custom_models, per: :month
    end

    assert PricingPlans::LimitableRegistry.counter_for(:projects)
    assert_nil PricingPlans::LimitableRegistry.counter_for(:custom_models)
  end
end
