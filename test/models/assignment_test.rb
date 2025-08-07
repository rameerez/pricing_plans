# frozen_string_literal: true

require "test_helper"

class AssignmentTest < ActiveSupport::TestCase
  def setup
    super  # This calls the test helper setup which configures plans
    @org = create_organization
  end

  def test_factory_creates_valid_assignment
    # Verify plans are configured
    assert PricingPlans::Registry.plan_exists?(:pro), "Pro plan should exist"
    
    assignment = PricingPlans::Assignment.create!(
      billable: @org,
      plan_key: "pro",
      source: "manual"
    )
    
    assert assignment.valid?
    assert_equal @org, assignment.billable
    assert_equal "pro", assignment.plan_key
    assert_equal "manual", assignment.source
  end

  def test_validation_requires_billable
    assignment = PricingPlans::Assignment.new(
      plan_key: "pro",
      source: "manual"
    )
    
    refute assignment.valid?
    assert assignment.errors[:billable].any?
  end

  def test_validation_requires_plan_key
    assignment = PricingPlans::Assignment.new(
      billable: @org,
      source: "manual"
    )
    
    refute assignment.valid?
    assert assignment.errors[:plan_key].any?
  end

  def test_validation_requires_source
    assignment = PricingPlans::Assignment.new(
      billable: @org,
      plan_key: "pro",
      source: nil  # Explicitly set to nil since it has default
    )
    
    refute assignment.valid?
    assert assignment.errors[:source].any?
  end

  def test_source_defaults_to_manual
    assignment = PricingPlans::Assignment.create!(
      billable: @org,
      plan_key: "pro"
    )
    
    assert_equal "manual", assignment.source
  end

  def test_uniqueness_per_billable
    PricingPlans::Assignment.create!(
      billable: @org,
      plan_key: "pro",
      source: "manual"
    )
    
    duplicate = PricingPlans::Assignment.new(
      billable: @org,
      plan_key: "enterprise",
      source: "admin"
    )
    
    refute duplicate.valid?
    assert duplicate.errors[:billable_type].any?
  end

  def test_different_billables_can_have_assignments
    org2 = create_organization
    
    assignment1 = PricingPlans::Assignment.create!(
      billable: @org,
      plan_key: "pro",
      source: "manual"
    )
    
    assignment2 = PricingPlans::Assignment.create!(
      billable: org2,
      plan_key: "enterprise",
      source: "admin"
    )
    
    assert assignment1.valid?
    assert assignment2.valid?
  end

  def test_polymorphic_billable_association
    assignment = PricingPlans::Assignment.create!(
      billable: @org,
      plan_key: "pro"
    )
    
    assert_equal @org, assignment.billable
    assert_equal "Organization", assignment.billable_type
    assert_equal @org.id, assignment.billable_id
  end

  def test_assign_plan_to_class_method
    result = PricingPlans::Assignment.assign_plan_to(@org, :enterprise, source: "admin")
    
    assert result.persisted?
    assert_equal "enterprise", result.plan_key
    assert_equal "admin", result.source
    assert_equal @org, result.billable
  end

  def test_assign_plan_to_updates_existing_assignment
    existing = PricingPlans::Assignment.create!(
      billable: @org,
      plan_key: "pro",
      source: "manual"
    )
    
    updated = PricingPlans::Assignment.assign_plan_to(@org, :enterprise, source: "admin")
    
    assert_equal existing.id, updated.id
    assert_equal "enterprise", updated.plan_key
    assert_equal "admin", updated.source
  end

  def test_assign_plan_to_with_string_plan_key
    result = PricingPlans::Assignment.assign_plan_to(@org, "pro")
    
    assert_equal "pro", result.plan_key
  end

  def test_remove_assignment_for_class_method
    PricingPlans::Assignment.create!(
      billable: @org,
      plan_key: "pro"
    )
    
    assert_difference "PricingPlans::Assignment.count", -1 do
      PricingPlans::Assignment.remove_assignment_for(@org)
    end
  end

  def test_remove_assignment_for_nonexistent_assignment
    assert_no_difference "PricingPlans::Assignment.count" do
      PricingPlans::Assignment.remove_assignment_for(@org)
    end
  end

  def test_find_by_billable
    assignment = PricingPlans::Assignment.create!(
      billable: @org,
      plan_key: "pro"
    )
    
    found = PricingPlans::Assignment.find_by(
      billable_type: @org.class.name,
      billable_id: @org.id
    )
    
    assert_equal assignment, found
  end

  def test_integration_with_plan_resolver
    PricingPlans::Assignment.assign_plan_to(@org, :pro)
    
    resolved_plan = PricingPlans::PlanResolver.effective_plan_for(@org)
    assert_equal :pro, resolved_plan.key
  end

  def test_multiple_sources
    # Test different source types
    sources = ["manual", "admin", "api", "migration", "trial_conversion"]
    
    sources.each_with_index do |source, index|
      org = create_organization
      assignment = PricingPlans::Assignment.create!(
        billable: org,
        plan_key: "pro",
        source: source
      )
      
      assert assignment.valid?
      assert_equal source, assignment.source
    end
  end

  def test_assignment_history_via_timestamps
    travel_to(Time.parse("2025-01-01 12:00:00 UTC")) do
      assignment = PricingPlans::Assignment.create!(
        billable: @org,
        plan_key: "free"
      )
      
      assert_in_delta Time.parse("2025-01-01 12:00:00 UTC"), assignment.created_at, 1.second
    end
    
    travel_to(Time.parse("2025-01-15 12:00:00 UTC")) do
      assignment = PricingPlans::Assignment.find_by(billable: @org)
      PricingPlans::Assignment.assign_plan_to(@org, :pro, source: "upgrade")
      
      updated_assignment = PricingPlans::Assignment.find_by(billable: @org)
      assert updated_assignment.updated_at > assignment.updated_at
    end
  end
end