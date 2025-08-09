# frozen_string_literal: true

require "test_helper"

class ComplexAssociationsTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan   = :free
      config.plan :free do
        limits :ai_models, to: 1
        limits :deeply_nested_resources, to: 2
      end
    end
  end

  def test_custom_limit_key_and_foreign_key
    # Define child with different class name and table but using same projects table for reuse
    Object.const_set(:CustomAiModel, Class.new(ActiveRecord::Base))
    CustomAiModel.class_eval do
      self.table_name = "projects"
      belongs_to :company, class_name: "Organization", foreign_key: "organization_id"
    end

    # Extend Organization with non-standard association
    Organization.class_eval do
      include PricingPlans::Billable unless included_modules.include?(PricingPlans::Billable)
      has_many :ai_models,
        class_name: "CustomAiModel",
        foreign_key: "organization_id",
        limited_by_pricing_plans: { limit_key: :ai_models, error_after_limit: "Too many AI models!" }
    end

    org = Organization.create!(name: "ACME")
    CustomAiModel.create!(name: "M1", company: org)

    # English sugar generated
    assert_respond_to org, :ai_models_within_plan_limits?
    assert_respond_to org, :ai_models_remaining
    assert_equal false, org.ai_models_within_plan_limits?(by: 1)
    assert_includes CustomAiModel.pricing_plans_limits.keys, :ai_models
    assert_equal :company, CustomAiModel.pricing_plans_limits[:ai_models][:billable_method]
  ensure
    Object.send(:remove_const, :CustomAiModel) if defined?(CustomAiModel)
  end

  def test_deeply_nested_association_and_sugar
    # Simulate a namespaced model name
    Object.const_set(:Deeply, Module.new) unless defined?(Deeply)
    Deeply.const_set(:NestedResource, Class.new(ActiveRecord::Base))
    Deeply::NestedResource.class_eval do
      self.table_name = "projects"
      belongs_to :organization
    end

    Organization.class_eval do
      include PricingPlans::Billable unless included_modules.include?(PricingPlans::Billable)
      has_many :deeply_nested_resources,
        class_name: "Deeply::NestedResource",
        limited_by_pricing_plans: true
    end

    org = Organization.create!(name: "Deep Org")
    Deeply::NestedResource.create!(name: "R1", organization: org)
    Deeply::NestedResource.create!(name: "R2", organization: org)

    # English sugar for plural, limit is 2 → next should be blocked
    assert_respond_to org, :deeply_nested_resources_within_plan_limits?
    assert_equal false, org.deeply_nested_resources_within_plan_limits?(by: 1)
    assert :deeply_nested_resources, Deeply::NestedResource.pricing_plans_limits.keys
    assert_equal :organization, Deeply::NestedResource.pricing_plans_limits[:deeply_nested_resources][:billable_method]
  ensure
    Deeply.send(:remove_const, :NestedResource) if defined?(Deeply::NestedResource)
    Object.send(:remove_const, :Deeply) if defined?(Deeply)
  end
end
