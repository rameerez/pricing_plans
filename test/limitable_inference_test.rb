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
