# frozen_string_literal: true

require "test_helper"

class OverageReporterTest < ActiveSupport::TestCase
  def test_overage_report_for_persistent_and_per_period
    org = create_organization

    # Persistent cap: projects
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    org.projects.create!(name: "P1")
    org.projects.create!(name: "P2")

    # Target: free plan allows 1 project → over by 1
    items = PricingPlans::OverageReporter.report(org, :free)
    projects_item = items.find { |i| i.limit_key == :projects }

    assert projects_item, "Expected projects overage"
    assert_equal :persistent, projects_item.kind
    assert_equal 2, projects_item.current_usage
    assert_equal 1, projects_item.allowed
    assert_equal 1, projects_item.overage

    # Per period: custom_models (free allows 0, pro allows 3); assign pro, use 3, then report vs free
    PricingPlans::Assignment.assign_plan_to(org, :pro)
    3.times { |i| org.custom_models.create!(name: "M#{i}") }

    items = PricingPlans::OverageReporter.report(org, :free)
    custom_item = items.find { |i| i.limit_key == :custom_models }
    assert custom_item, "Expected custom_models overage"
    assert_equal :per_period, custom_item.kind
    assert custom_item.current_usage >= 3
    assert_equal 0, custom_item.allowed
    assert custom_item.overage >= 3
  end
end
