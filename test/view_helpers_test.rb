# frozen_string_literal: true

require "test_helper"

class ViewHelpersTest < ActiveSupport::TestCase

  def setup
    super
    @org = create_organization
  end

  # Test the helper logic without relying on ActionView
  # These test the business logic of the helpers

  def test_plan_allows_with_allowed_feature
    plan = PricingPlans::Plan.new(:pro)
    plan.allows(:api_access)

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      assert @org.plan_allows?(:api_access)
    end
  end

  def test_plan_allows_with_disallowed_feature
    plan = PricingPlans::Plan.new(:free)

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      refute @org.plan_allows?(:api_access)
    end
  end

  def test_plan_limit_remaining
    PricingPlans::LimitChecker.stub(:plan_limit_remaining, 5) do
      assert_equal 5, @org.plan_limit_remaining(:projects)
    end
  end

  def test_plan_limit_remaining_unlimited
    PricingPlans::LimitChecker.stub(:plan_limit_remaining, :unlimited) do
      assert_equal :unlimited, @org.plan_limit_remaining(:projects)
    end
  end

  def test_plan_limit_percent_used
    PricingPlans::LimitChecker.stub(:plan_limit_percent_used, 75.5) do
      assert_equal 75.5, @org.plan_limit_percent_used(:projects)
    end
  end

  def test_limit_status_basic
    status = PricingPlans.limit_status(:projects, billable: @org)
    assert_equal true, status[:configured]
    assert_equal :projects, status[:limit_key]
    assert_includes [:unlimited, Integer], status[:limit_amount].class
    assert_includes [true, false], status[:grace_active]
    assert_includes [true, false], status[:blocked]
  end

  def test_plans_returns_array
    data = PricingPlans.plans
    assert data.is_a?(Array)
    assert data.first.is_a?(PricingPlans::Plan)
  end

  def test_aggregate_helpers
    org = @org
    # No grace initially
    refute org.any_grace_active_for?(:projects, :custom_models)

    # Start grace for projects and ensure aggregation reflects it
    PricingPlans::GraceManager.mark_exceeded!(org, :projects)
    assert org.any_grace_active_for?(:projects, :custom_models)

    # Earliest grace ends at should be set and be a Time
    t = org.earliest_grace_ends_at_for(:projects, :custom_models)
    assert t.is_a?(Time)
  end

  def test_plan_limit_statuses_bulk
    org = @org
    statuses = PricingPlans.limit_statuses(:projects, :custom_models, billable: org)
    assert statuses.is_a?(Hash)
    assert statuses.key?(:projects)
    assert statuses.key?(:custom_models)
    assert_includes [true, false], statuses[:projects][:configured]
  end

  def test_highest_severity_for_many_limits
    org = @org
    # Initially should be ok
    assert_equal :ok, PricingPlans.highest_severity_for(org, :projects, :custom_models)

    # Exceed projects to enter grace
    PricingPlans::Assignment.assign_plan_to(org, :free)
    # Use a temporary plan that opts into grace semantics for this test
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 0, after_limit: :grace_then_block, grace: 2.days
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      result = PricingPlans::ControllerGuards.require_plan_limit!(:projects, billable: org)
      assert result.grace?
      assert_equal :grace, PricingPlans.highest_severity_for(org, :projects, :custom_models)
    end
  end

  def test_combine_messages_for
    org = @org
    org.projects.create!(name: "P1")
    msg = PricingPlans.combine_messages_for(org, :projects, :custom_models)
    assert msg.nil? || msg.is_a?(String)
  end

  def test_price_label_helper
    plans = []
    p_free = PricingPlans::Plan.new(:free)
    p_free.price(0)
    plans << p_free

    p_pro = PricingPlans::Plan.new(:pro)
    p_pro.price(29)
    plans << p_pro

    p_ent = PricingPlans::Plan.new(:ent)
    p_ent.price_string("Contact")
    plans << p_ent

    labels = plans.map(&:price_label)
    assert_match(/Free/, labels[0])
    assert_match(/\$29\/mo/, labels[1])
    assert_equal "Contact", labels[2]
  end

  def test_suggest_next_plan_for
    org = @org
    # Configure a small custom set of plans for determinism
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        price 0
        limits :projects, to: 1, after_limit: :grace_then_block, grace: 7.days
      end

      config.plan :basic do
        price 10
        limits :projects, to: 3, after_limit: :grace_then_block, grace: 7.days
      end

      config.plan :pro do
        price 20
        limits :projects, to: 10, after_limit: :grace_then_block, grace: 7.days
      end
    end

    # Re-register counters cleared by reset_configuration!
    Project.send(:limited_by_pricing_plans, :projects, billable: :organization)

    # usage 0 -> suggest free
    assert_equal :free, PricingPlans.suggest_next_plan_for(org, keys: [:projects]).key

    # usage 2 -> suggest basic
    2.times { |i| org.projects.create!(name: "P#{i}") }
    assert_equal :basic, PricingPlans.suggest_next_plan_for(org, keys: [:projects]).key

    # usage 5 -> suggest pro
    3.times { |i| org.projects.create!(name: "Q#{i}") }
    assert_equal :pro, PricingPlans.suggest_next_plan_for(org, keys: [:projects]).key
  end
end
