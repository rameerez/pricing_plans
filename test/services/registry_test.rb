# frozen_string_literal: true

require "test_helper"

class RegistryTest < ActiveSupport::TestCase
  def setup
    super
    # Reset configuration for each test since we're testing configuration itself
    PricingPlans.reset_configuration!
  end

  def test_builds_from_configuration
    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        price 0
      end
    end

    registry = PricingPlans::Registry

    assert_equal 1, registry.plans.size
    assert registry.plan_exists?(:free)
    assert_equal "Free", registry.plan(:free).name
  end

  def test_plan_not_found_error
    error = assert_raises(PricingPlans::PlanNotFoundError) do
      PricingPlans::Registry.plan(:nonexistent)
    end

    assert_match(/Plan nonexistent not found/, error.message)
  end

  def test_billable_class_resolution_from_string
    PricingPlans.configure do |config|
      config.billable_class = "Organization"
      config.default_plan = :free

      config.plan :free do
        price 0
      end
    end

    assert_equal Organization, PricingPlans::Registry.billable_class
  end

  def test_billable_class_resolution_from_class
    PricingPlans.configure do |config|
      config.billable_class = Organization
      config.default_plan = :free

      config.plan :free do
        price 0
      end
    end

    assert_equal Organization, PricingPlans::Registry.billable_class
  end

  def test_billable_class_invalid_type
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.billable_class = 123  # Invalid type
        config.default_plan = :free

        config.plan :free do
          price 0
        end
      end
    end

    assert_match(/billable_class must be a string or class/, error.message)
  end

  def test_default_and_highlighted_plan_resolution
    PricingPlans.configure do |config|
      config.plan :free do
        price 0
        default!
      end

      config.plan :pro do
        price 29
        highlighted!
      end
    end

    registry = PricingPlans::Registry

    assert_equal :free, registry.default_plan.key
    assert_equal :pro, registry.highlighted_plan.key
  end

  def test_duplicate_stripe_price_validation
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :free

        config.plan :free do
          price 0
        end

        config.plan :pro do
          stripe_price "price_123"
        end

        config.plan :premium do
          stripe_price "price_123"  # Duplicate!
        end
      end
    end

    assert_match(/Duplicate Stripe price IDs found: price_123/, error.message)
  end

  def test_limit_consistency_validation
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :free

        config.plan :free do
          price 0
          limits :projects, to: 1  # No 'per' option
        end

        config.plan :pro do
          price 29
          limits :projects, to: 10, per: :month  # Has 'per' option - inconsistent!
        end
      end
    end

    assert_match(/Inconsistent 'per' configuration for limit 'projects'/, error.message)
  end

  def test_usage_credits_integration_linting_with_stubbed_gem
    stub_usage_credits_available

    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :free

        config.plan :free do
          price 0
          includes_credits 100, for: :api_calls
          limits :api_calls, to: 50, per: :month  # Collision!
        end
      end
    end

    # With stricter linting, unknown ops or collisions should still be caught; accept either error
    assert_match(/(defines both includes_credits and a per-period limit|includes_credits for unknown)/, error.message)

  ensure
    unstub_usage_credits
  end

  def test_usage_credits_operation_validation_warning
    stub_usage_credits_available

    # Now should error when usage_credits is present and operation is unknown
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :free

        config.plan :free do
          price 0
          includes_credits 100, for: :unknown_operation
        end
      end
    end

    assert_match(/includes_credits for unknown usage_credits operation 'unknown_operation'/, error.message)

  ensure
    unstub_usage_credits
  end

  def test_event_emission
    handler_called = false
    handler_args = nil

    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        price 0
      end

      config.on_warning :projects do |billable, threshold|
        handler_called = true
        handler_args = [billable, threshold]
      end
    end

    org = create_organization
    PricingPlans::Registry.emit_event(:warning, :projects, org, 0.8)

    assert handler_called
    assert_equal [org, 0.8], handler_args
  end

  def test_event_emission_with_no_handler
    # Should not raise error when no handler registered
    org = create_organization

    assert_nothing_raised do
      PricingPlans::Registry.emit_event(:warning, :nonexistent, org, 0.8)
    end
  end

  def test_clear_registry
    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        price 0
      end
    end

    refute_empty PricingPlans::Registry.plans

    PricingPlans::Registry.clear!

    assert_empty PricingPlans::Registry.plans
    assert_nil PricingPlans::Registry.configuration
  end

  def test_registry_without_configuration
    PricingPlans::Registry.clear!

    assert_empty PricingPlans::Registry.plans
    assert_nil PricingPlans::Registry.billable_class
    assert_nil PricingPlans::Registry.default_plan
    assert_nil PricingPlans::Registry.highlighted_plan
  end

  def test_complex_stripe_price_collision_detection
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :free

        config.plan :free do
          price 0
        end

        config.plan :pro do
          stripe_price({ month: "price_month", year: "price_year" })
        end

        config.plan :premium do
          stripe_price "price_month"  # Collides with pro's month price
        end
      end
    end

    assert_match(/Duplicate Stripe price IDs/, error.message)
  end

  def test_event_handlers_structure
    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        price 0
      end

      config.on_warning :projects do |billable, threshold|
        # handler
      end

      config.on_grace_start :projects do |billable, ends_at|
        # handler
      end

      config.on_block :projects do |billable|
        # handler
      end
    end

    handlers = PricingPlans::Registry.event_handlers

    assert handlers[:warning][:projects].is_a?(Proc)
    assert handlers[:grace_start][:projects].is_a?(Proc)
    assert handlers[:block][:projects].is_a?(Proc)
  end

  private

  def capture_io
    old_stdout = $stdout
    old_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new

    yield

    [$stderr.string, $stdout.string]
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end
end
