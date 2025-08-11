# frozen_string_literal: true

require "test_helper"

class ViewHelpersTest < ActiveSupport::TestCase
  include PricingPlans::ViewHelpers

  def setup
    super
    @org = create_organization
  end

  # Test the helper logic without relying on ActionView
  # These test the business logic of the helpers

  def test_current_plan_name_with_plan
    plan = PricingPlans::Plan.new(:pro)
    plan.name("Pro Plan")

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      assert_equal "Pro Plan", current_plan_name(@org)
    end
  end

  def test_current_plan_name_without_plan
    PricingPlans::PlanResolver.stub(:effective_plan_for, nil) do
      assert_equal "Unknown", current_plan_name(@org)
    end
  end

  def test_plan_allows_with_allowed_feature
    plan = PricingPlans::Plan.new(:pro)
    plan.allows(:api_access)

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      assert plan_allows?(@org, :api_access)
    end
  end

  def test_plan_allows_with_disallowed_feature
    plan = PricingPlans::Plan.new(:free)

    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      refute plan_allows?(@org, :api_access)
    end
  end

  def test_plan_allows_without_plan
    PricingPlans::PlanResolver.stub(:effective_plan_for, nil) do
      refute plan_allows?(@org, :api_access)
    end
  end

  def test_plan_limit_remaining
    PricingPlans::LimitChecker.stub(:plan_limit_remaining, 5) do
      assert_equal 5, plan_limit_remaining(@org, :projects)
    end
  end

  def test_plan_limit_remaining_unlimited
    PricingPlans::LimitChecker.stub(:plan_limit_remaining, :unlimited) do
      assert_equal :unlimited, plan_limit_remaining(@org, :projects)
    end
  end

  def test_plan_limit_percent_used
    PricingPlans::LimitChecker.stub(:plan_limit_percent_used, 75.5) do
      assert_equal 75.5, plan_limit_percent_used(@org, :projects)
    end
  end

  def test_plan_limit_status_basic
    status = plan_limit_status(:projects, billable: @org)
    assert_equal true, status[:configured]
    assert_equal :projects, status[:limit_key]
    assert_includes [:unlimited, Integer], status[:limit_amount].class
    assert_includes [true, false], status[:grace_active]
    assert_includes [true, false], status[:blocked]
  end

  def test_render_plan_limit_status_returns_html
    # Stub content_tag to a simple wrapper for testing without ActionView
    self.define_singleton_method(:content_tag) do |name, *args, **kwargs, &block|
      inner = block ? block.call : args.first
      "<#{name}>#{inner}</#{name}>"
    end
    # Stub html_safe on String
    String.class_eval do
      def html_safe
        self
      end
    end

    html = render_plan_limit_status(:projects, billable: @org)
    assert html.is_a?(String)
    assert_operator html.length, :>, 0
    assert_match(/projects/i, html)
  end

  def test_view_helpers_module_exists
    assert defined?(PricingPlans::ViewHelpers)
    assert PricingPlans::ViewHelpers.is_a?(Module)
  end

  def test_view_helpers_can_be_included
    # Test that the module can be included (as it would be in a Rails view)
    test_class = Class.new do
      include PricingPlans::ViewHelpers
    end

    instance = test_class.new

    # Test that the methods are available
    assert_respond_to instance, :current_plan_name
    assert_respond_to instance, :plan_allows?
    assert_respond_to instance, :plan_limit_remaining
    assert_respond_to instance, :plan_limit_percent_used
  end

  def test_aggregate_helpers
    org = @org
    # No grace initially
    refute any_grace_active_for?(org, :projects, :custom_models)

    # Start grace for projects and ensure aggregation reflects it
    PricingPlans::GraceManager.mark_exceeded!(org, :projects)
    assert any_grace_active_for?(org, :projects, :custom_models)

    # Earliest grace ends at should be set and be a Time
    t = earliest_grace_ends_at_for(org, :projects, :custom_models)
    assert t.is_a?(Time)
  end

  def test_plan_limit_statuses_bulk
    org = @org
    statuses = plan_limit_statuses(:projects, :custom_models, billable: org)
    assert statuses.is_a?(Hash)
    assert statuses.key?(:projects)
    assert statuses.key?(:custom_models)
    assert_includes [true, false], statuses[:projects][:configured]
  end

  def test_highest_severity_for_many_limits
    org = @org
    # Initially should be ok
    assert_equal :ok, highest_severity_for(org, :projects, :custom_models)

    # Exceed projects to enter grace
    PricingPlans::Assignment.assign_plan_to(org, :free)
    # Use a temporary plan that opts into grace semantics for this test
    plan = PricingPlans::Plan.new(:tmp)
    plan.limits :projects, to: 0, after_limit: :grace_then_block, grace: 2.days
    PricingPlans::PlanResolver.stub(:effective_plan_for, plan) do
      result = PricingPlans::ControllerGuards.require_plan_limit!(:projects, billable: org)
      assert result.grace?
      assert_equal :grace, highest_severity_for(org, :projects, :custom_models)
    end
  end

  def test_combine_messages_for
    org = @org
    org.projects.create!(name: "P1")
    msg = combine_messages_for(org, :projects, :custom_models)
    assert msg.nil? || msg.is_a?(String)
  end

  def test_plan_label_helper
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

    labels = plans.map { |p| plan_label(p) }
    assert_equal ["Free"], labels[0][1].scan(/Free/)
    assert_match(/\$29\/mo/, labels[1][1])
    assert_equal "Contact", labels[2][1]
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
    assert_equal :free, suggest_next_plan_for(org, keys: [:projects]).key

    # usage 2 -> suggest basic
    2.times { |i| org.projects.create!(name: "P#{i}") }
    assert_equal :basic, suggest_next_plan_for(org, keys: [:projects]).key

    # usage 5 -> suggest pro
    3.times { |i| org.projects.create!(name: "Q#{i}") }
    assert_equal :pro, suggest_next_plan_for(org, keys: [:projects]).key
  end
end
