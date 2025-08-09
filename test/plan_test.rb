# frozen_string_literal: true

require "test_helper"

class PlanTest < ActiveSupport::TestCase
  def test_basic_plan_creation
    plan = PricingPlans::Plan.new(:free)

    assert_equal :free, plan.key
    assert_equal "Free", plan.name  # auto-titleized
    assert_nil plan.description
    assert_empty plan.bullets
  end

  def test_plan_dsl_methods
    plan = PricingPlans::Plan.new(:pro)

    plan.name "Professional"
    plan.description "For growing teams"
    plan.bullets "Feature 1", "Feature 2"
    plan.price 29

    assert_equal "Professional", plan.name
    assert_equal "For growing teams", plan.description
    assert_equal ["Feature 1", "Feature 2"], plan.bullets
    assert_equal 29, plan.price
  end

  def test_plan_cta_defaults_and_overrides
    # Configure defaults
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan :free do
        price 0
      end
    end

    plan = PricingPlans::Plan.new(:pro)
    plan.name "Pro"
    plan.price 10

    # Without overrides, derives a sensible default text, url nil
    assert_match(/Choose Pro/i, plan.cta_text)
    assert_nil plan.cta_url

    # With global defaults
    PricingPlans.configuration.default_cta_text = "Choose plan"
    PricingPlans.configuration.default_cta_url  = "/checkout"
    assert_equal "Choose plan", plan.cta_text
    assert_equal "/checkout",  plan.cta_url

    # Per-plan overrides win
    plan.cta_text "Upgrade now"
    plan.cta_url  "https://example.com/upgrade"
    assert_equal "Upgrade now", plan.cta_text
    assert_equal "https://example.com/upgrade", plan.cta_url
  end

  def test_stripe_price_configuration
    plan = PricingPlans::Plan.new(:pro)

    # String format
    plan.stripe_price "price_123"
    assert_equal({ id: "price_123" }, plan.stripe_price)

    # Hash format
    plan.stripe_price({ month: "price_month", year: "price_year" })
    assert_equal({ month: "price_month", year: "price_year" }, plan.stripe_price)
  end

  def test_stripe_price_invalid_format
    plan = PricingPlans::Plan.new(:pro)

    error = assert_raises(PricingPlans::ConfigurationError) do
      plan.stripe_price 12345  # Not string or hash
    end

    assert_match(/stripe_price must be a string or hash/, error.message)
  end

  def test_feature_flags
    plan = PricingPlans::Plan.new(:pro)

    plan.allows :api_access, :premium_features
    plan.disallows :enterprise_sso

    assert plan.allows_feature?(:api_access)
    assert plan.allows_feature?(:premium_features)
    refute plan.allows_feature?(:enterprise_sso)
    refute plan.allows_feature?(:nonexistent_feature)
  end

  def test_feature_flag_aliases
    plan = PricingPlans::Plan.new(:pro)

    # Test singular aliases
    plan.allow :api_access
    plan.disallow :enterprise_sso

    assert plan.allows_feature?(:api_access)
    refute plan.allows_feature?(:enterprise_sso)
  end

  def test_limits_configuration
    plan = PricingPlans::Plan.new(:pro)

    plan.limits :projects, to: 5, after_limit: :grace_then_block, grace: 7.days

    limit = plan.limit_for(:projects)
    assert_equal :projects, limit[:key]
    assert_equal 5, limit[:to]
    assert_equal :grace_then_block, limit[:after_limit]
    assert_equal 7.days, limit[:grace]
    assert_equal [0.6, 0.8, 0.95], limit[:warn_at]  # defaults
  end

  def test_limit_singular_alias
    plan = PricingPlans::Plan.new(:pro)

    plan.limit :projects, to: 10

    limit = plan.limit_for(:projects)
    assert_equal 10, limit[:to]
  end

  def test_unlimited_limits
    plan = PricingPlans::Plan.new(:enterprise)

    plan.unlimited :projects, :users

    projects_limit = plan.limit_for(:projects)
    users_limit = plan.limit_for(:users)

    assert_equal :unlimited, projects_limit[:to]
    assert_equal :unlimited, users_limit[:to]
  end

  def test_limits_validation_invalid_to_value
    plan = PricingPlans::Plan.new(:pro)

    error = assert_raises(PricingPlans::ConfigurationError) do
      plan.limits :projects, to: "invalid"
      plan.validate!
    end

    assert_match(/must be :unlimited, Integer, or respond to to_i/, error.message)
  end

  def test_limits_validation_invalid_after_limit
    plan = PricingPlans::Plan.new(:pro)

    error = assert_raises(PricingPlans::ConfigurationError) do
      plan.limits :projects, to: 5, after_limit: :invalid_behavior
      plan.validate!
    end

    assert_match(/after_limit must be one of/, error.message)
  end

  def test_limits_validation_grace_with_just_warn
    plan = PricingPlans::Plan.new(:pro)

    error = assert_raises(PricingPlans::ConfigurationError) do
      plan.limits :projects, to: 5, after_limit: :just_warn, grace: 7.days
      plan.validate!
    end

    assert_match(/cannot have grace with :just_warn/, error.message)
  end

  def test_limits_validation_invalid_warn_thresholds
    plan = PricingPlans::Plan.new(:pro)

    error = assert_raises(PricingPlans::ConfigurationError) do
      plan.limits :projects, to: 5, warn_at: [0.5, 1.5]  # 1.5 is > 1
      plan.validate!
    end

    assert_match(/warn_at thresholds must be numbers between 0 and 1/, error.message)
  end

  def test_per_period_limits
    plan = PricingPlans::Plan.new(:pro)

    plan.limits :custom_models, to: 3, per: :month

    limit = plan.limit_for(:custom_models)
    assert_equal :month, limit[:per]
  end

  def test_credit_inclusions
    plan = PricingPlans::Plan.new(:pro)

    plan.includes_credits 1000, for: :api_calls

    inclusion = plan.credit_inclusion_for(:api_calls)
    assert_equal 1000, inclusion[:amount]
    assert_equal :api_calls, inclusion[:operation]
  end

  def test_plan_metadata
    plan = PricingPlans::Plan.new(:enterprise)

    plan.meta support_tier: "dedicated", sla: "99.9%"

    assert_equal "dedicated", plan.meta[:support_tier]
    assert_equal "99.9%", plan.meta[:sla]
  end

  def test_pricing_validation_multiple_pricing_fields
    plan = PricingPlans::Plan.new(:pro)

    error = assert_raises(PricingPlans::ConfigurationError) do
      plan.price 29
      plan.price_string "Contact us"
      plan.validate!
    end

    assert_match(/can only have one of: price, price_string, or stripe_price/, error.message)
  end

  def test_integer_max_refinement
    plan = PricingPlans::Plan.new(:pro)

    # Test that integers work normally in plan limits
    plan.limits :projects, to: 5

    limit = plan.limit_for(:projects)
    assert_equal 5, limit[:to]
  end

  def test_bullets_flatten_arrays
    plan = PricingPlans::Plan.new(:pro)

    plan.bullets ["Feature 1", "Feature 2"], "Feature 3"

    assert_equal ["Feature 1", "Feature 2", "Feature 3"], plan.bullets
  end

  def test_empty_plan_validation_passes
    plan = PricingPlans::Plan.new(:minimal)

    # Should not raise
    assert_nothing_raised do
      plan.validate!
    end
  end

  def test_limit_defaults
    plan = PricingPlans::Plan.new(:pro)

    plan.limits :projects, to: 5  # Use all defaults

    limit = plan.limit_for(:projects)
    assert_equal :grace_then_block, limit[:after_limit]
    assert_equal 7.days, limit[:grace]
    assert_equal [0.6, 0.8, 0.95], limit[:warn_at]
  end

  def test_nonexistent_limit_returns_nil
    plan = PricingPlans::Plan.new(:pro)

    assert_nil plan.limit_for(:nonexistent)
  end

  def test_nonexistent_credit_inclusion_returns_nil
    plan = PricingPlans::Plan.new(:pro)

    assert_nil plan.credit_inclusion_for(:nonexistent)
  end
end
