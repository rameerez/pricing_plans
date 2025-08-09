# frozen_string_literal: true

require "test_helper"

class MessageBuilderTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.plan :free do
        price 0
        limits :projects, to: 1
        default!
      end
      config.plan :pro do
        price 20
        highlighted!
        limits :projects, to: 10
      end
    end
    # Re-register counters after config reset
    Project.send(:limited_by_pricing_plans, :projects, billable: :organization) if Project.respond_to?(:limited_by_pricing_plans)
    @org = create_organization
    @builder_calls = []
    PricingPlans.configuration.message_builder = ->(**kwargs) do
      @builder_calls << kwargs
      "Built: #{kwargs[:context]}"
    end
  end

  def test_feature_denied_uses_message_builder
    error = assert_raises(PricingPlans::FeatureDenied) do
      PricingPlans::ControllerGuards.require_feature!(:api_access, billable: @org)
    end
    assert_match(/Built: feature_denied/, error.message)
    assert @builder_calls.any? { |k| k[:context] == :feature_denied }
  end

  def test_over_limit_and_grace_messages_use_message_builder
    # Hit the limit to trigger grace path
    # free allows 1 project; create 2 and then require by 1 should exceed
    2.times { |i| @org.projects.create!(name: "P#{i}") }
    res = PricingPlans::ControllerGuards.require_plan_limit!(:projects, billable: @org, by: 1)
    assert (res.warning? || res.grace? || res.blocked?), "expected non-within result"
    used_contexts = @builder_calls.map { |k| k[:context] }.uniq
    assert used_contexts.include?(:over_limit) || used_contexts.include?(:grace)
  end

  def test_overage_report_message_builder
    # Increase usage for target plan overage
    5.times { |i| @org.projects.create!(name: "Q#{i}") }
    report = PricingPlans::OverageReporter.report_with_message(@org, :free)
    assert_match(/Built: overage_report/, report.message)
  end
end
