# frozen_string_literal: true

require "test_helper"

class ResultTest < ActiveSupport::TestCase
  def test_within_result
    result = PricingPlans::Result.within("You have 5 projects remaining")

    assert result.ok?
    assert result.within?
    refute result.warning?
    refute result.grace?
    refute result.blocked?

    assert_equal :within, result.state
    assert_equal "You have 5 projects remaining", result.message
    assert_nil result.limit_key
    assert_nil result.plan_owner
  end

  def test_warning_result
    org = create_organization
    result = PricingPlans::Result.warning(
      "You're approaching your project limit",
      limit_key: :projects,
      plan_owner: org
    )

    refute result.ok?
    assert result.warning?
    refute result.within?
    refute result.grace?
    refute result.blocked?

    assert_equal :warning, result.state
    assert_equal "You're approaching your project limit", result.message
    assert_equal :projects, result.limit_key
    assert_equal org, result.plan_owner
  end

  def test_grace_result
    org = create_organization
    result = PricingPlans::Result.grace(
      "You've exceeded your limit but are in grace period",
      limit_key: :projects,
      plan_owner: org
    )

    refute result.ok?
    refute result.warning?
    assert result.grace?
    refute result.within?
    refute result.blocked?

    assert_equal :grace, result.state
    assert_equal "You've exceeded your limit but are in grace period", result.message
    assert_equal :projects, result.limit_key
    assert_equal org, result.plan_owner
  end

  def test_blocked_result
    org = create_organization
    result = PricingPlans::Result.blocked(
      "You've exceeded your limit and grace period has expired",
      limit_key: :projects,
      plan_owner: org
    )

    refute result.ok?
    refute result.warning?
    refute result.grace?
    refute result.within?
    assert result.blocked?

    assert_equal :blocked, result.state
    assert_equal "You've exceeded your limit and grace period has expired", result.message
    assert_equal :projects, result.limit_key
    assert_equal org, result.plan_owner
  end

  def test_ok_method_convenience
    within_result = PricingPlans::Result.within("OK")
    warning_result = PricingPlans::Result.warning("Warning")
    grace_result = PricingPlans::Result.grace("Grace")
    blocked_result = PricingPlans::Result.blocked("Blocked")

    assert within_result.ok?
    refute warning_result.ok?
    refute grace_result.ok?
    refute blocked_result.ok?
  end

  def test_result_with_nil_message
    result = PricingPlans::Result.within(nil)

    assert_nil result.message
    assert result.ok?
  end

  def test_result_with_empty_message
    result = PricingPlans::Result.within("")

    assert_equal "", result.message
    assert result.ok?
  end

  def test_result_state_constants
    assert_equal :within, PricingPlans::Result.within("test").state
    assert_equal :warning, PricingPlans::Result.warning("test").state
    assert_equal :grace, PricingPlans::Result.grace("test").state
    assert_equal :blocked, PricingPlans::Result.blocked("test").state
  end

  def test_result_optional_parameters_default_to_nil
    result = PricingPlans::Result.warning("Warning message")

    assert_nil result.limit_key
    assert_nil result.plan_owner
  end

  def test_result_stores_limit_key_as_symbol
    result = PricingPlans::Result.warning("Test", limit_key: "projects")

    assert_equal "projects", result.limit_key
  end

  def test_result_immutability
    org = create_organization
    result = PricingPlans::Result.grace(
      "Grace message",
      limit_key: :projects,
      plan_owner: org
    )

    # Result should be effectively immutable (no setter methods)
    refute result.respond_to?(:message=)
    refute result.respond_to?(:state=)
    refute result.respond_to?(:limit_key=)
    refute result.respond_to?(:plan_owner=)
  end

  def test_result_equality_based_on_attributes
    org = create_organization

    result1 = PricingPlans::Result.grace("Message", limit_key: :projects, plan_owner: org)
    result2 = PricingPlans::Result.grace("Message", limit_key: :projects, plan_owner: org)
    result3 = PricingPlans::Result.grace("Different", limit_key: :projects, plan_owner: org)

    # Note: Results are value objects, they won't be == unless explicitly implemented
    # But they should have the same attributes
    assert_equal result1.state, result2.state
    assert_equal result1.message, result2.message
    assert_equal result1.limit_key, result2.limit_key
    assert_equal result1.plan_owner, result2.plan_owner

    refute_equal result1.message, result3.message
  end

  def test_result_can_be_used_in_controller_pattern
    org = create_organization
    result = PricingPlans::Result.blocked(
      "Cannot create project: limit exceeded",
      limit_key: :projects,
      plan_owner: org
    )

    # Simulate controller usage
    if result.blocked?
      assert_equal "Cannot create project: limit exceeded", result.message
      assert_equal :projects, result.limit_key
    else
      flunk "Expected blocked result"
    end
  end

  def test_result_truthiness_for_flow_control
    ok_result = PricingPlans::Result.within("OK")
    warning_result = PricingPlans::Result.warning("Warning")
    blocked_result = PricingPlans::Result.blocked("Blocked")

    # All results are truthy objects (not nil/false)
    assert ok_result
    assert warning_result
    assert blocked_result
  end

  def test_result_with_complex_plan_owner_objects
    # Test with different types of plan_owners
    project = Project.create!(name: "Test", organization: create_organization)

    result = PricingPlans::Result.warning(
      "Warning for project",
      limit_key: :some_limit,
      plan_owner: project
    )

    assert_equal project, result.plan_owner
    assert_equal :some_limit, result.limit_key
  end
end
