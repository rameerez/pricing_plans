# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
  end

  def test_basic_configuration_setup
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.highlighted_plan = :pro

      config.plan :free do
        price 0
      end

      config.plan :pro do
        price 10
      end
    end

    config = PricingPlans.configuration
    assert_equal :free, config.default_plan
    assert_equal :pro, config.highlighted_plan
  end

  # plan_owner_class is now optional; we infer via common conventions in controllers/models
  def test_plan_owner_class_is_optional
    assert_nothing_raised do
      PricingPlans.configure do |config|
        config.default_plan = :free
        config.plan :free do
          price 0
        end
      end
    end
  end

  def test_requires_default_plan
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        # No default_plan set explicitly, and no plan marked default via DSL
        config.plan :free do
          price 0
        end
      end
    end

    assert_match(/default_plan is required/, error.message)
  end
  def test_default_plan_can_be_marked_via_dsl
    PricingPlans.configure do |config|
      # No explicit default_plan
      config.plan :free do
        price 0
        default!
      end
    end

    assert_equal :free, PricingPlans.configuration.default_plan
    assert_equal :free, PricingPlans::Registry.default_plan.key
  end

  def test_highlighted_plan_can_be_marked_via_dsl
    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        price 0
        highlighted!
      end
    end

    assert_equal :free, PricingPlans::Registry.highlighted_plan.key
  end

  def test_multiple_default_markers_error
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.plan :free do
          price 0
          default!
        end

        config.plan :pro do
          price 10
          default!
        end
      end
    end

    assert_match(/Multiple plans marked default via DSL/, error.message)
  end

  def test_multiple_highlighted_markers_error
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :free

        config.plan :free do
          price 0
          highlighted!
        end

        config.plan :pro do
          price 10
          highlighted!
        end
      end
    end

    assert_match(/Multiple plans marked highlighted via DSL/, error.message)
  end


  def test_default_plan_must_be_defined
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :nonexistent
      end
    end

    assert_match(/default_plan nonexistent is not defined/, error.message)
  end

  def test_highlighted_plan_must_be_defined_if_set
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :free
        config.highlighted_plan = :nonexistent

        config.plan :free do
          price 0
        end
      end
    end

    assert_match(/highlighted_plan nonexistent is not defined/, error.message)
  end

  def test_duplicate_plan_keys_not_allowed
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :free

        config.plan :free do
          price 0
        end

        config.plan :free do  # Duplicate!
          price 0
        end
      end
    end

    assert_match(/Plan free already defined/, error.message)
  end

  def test_plan_keys_must_be_symbols
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :free

        config.plan "free" do  # String instead of symbol!
          price 0
        end
      end
    end

    assert_match(/Plan key must be a symbol/, error.message)
  end

  def test_event_handlers_require_blocks
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.plan_owner_class = "Organization"
        config.default_plan = :free

        config.plan :free do
          price 0
        end

        config.on_warning :projects  # No block!
      end
    end

    assert_match(/Block required for on_warning/, error.message)
  end

  def test_event_handlers_store_blocks
    handler_called = false

    PricingPlans.configure do |config|
      config.plan_owner_class = "Organization"
      config.default_plan = :free

      config.plan :free do
        price 0
      end

      config.on_warning :projects do |billable, threshold|
        handler_called = true
      end
    end

    config = PricingPlans.configuration
    assert config.event_handlers[:warning][:projects].is_a?(Proc)

    # Test handler execution
    config.event_handlers[:warning][:projects].call(nil, 0.8)
    assert handler_called
  end

  def test_reset_configuration_clears_everything
    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        price 0
      end
    end

    # plan_owner_class is optional now; not set
    assert_nil PricingPlans.configuration.plan_owner_class

    PricingPlans.reset_configuration!

    assert_nil PricingPlans.configuration.plan_owner_class
  end

  def test_malformed_plan_blocks_handled
    error = assert_raises do
      PricingPlans.configure do |config|
        config.default_plan = :free

        config.plan :free do
          raise "Something went wrong in plan block"
        end
      end
    end

    assert_match(/Something went wrong/, error.message)
  end

  def test_billable_convenience_methods_via_instance
    setup_test_plans
    org = Organization.create!(name: "Org")
    # Re-register counters after configuring in this test
    Project.send(:limited_by_pricing_plans, :projects, plan_owner: :organization) if Project.respond_to?(:limited_by_pricing_plans)
    assert_equal :free, PricingPlans::PlanResolver.plan_key_for(org)
    Project.create!(organization: org)
    # At free plan, projects limit is 1 in test helper; next by:1 should be blocked
    assert_equal false, org.within_plan_limits?(:projects, by: 1)
    assert_equal 0, org.plan_limit_remaining(:projects)
    assert_equal 100.0, org.plan_limit_percent_used(:projects)
    assert_equal :free, org.current_pricing_plan.key
  end

  def test_assign_and_remove_pricing_plan_via_billable
    setup_test_plans
    org = Organization.create!(name: "Org")
    Project.send(:limited_by_pricing_plans, :projects, plan_owner: :organization) if Project.respond_to?(:limited_by_pricing_plans)
    assert_equal :free, PricingPlans::PlanResolver.plan_key_for(org)
    # default free
    assert_equal :free, org.current_pricing_plan.key
    # assign pro
    org.assign_pricing_plan!(:pro)
    assert_equal :pro, org.current_pricing_plan.key
    # remove assignment -> back to default
    org.remove_pricing_plan!
    assert_equal :free, org.current_pricing_plan.key
  end

  def test_bare_dsl_inside_yielded_block
    PricingPlans.configure do |config|
      config.default_plan = :free

      # Bare DSL despite yielded config
      plan :free do
        price 0
      end
    end

    config = PricingPlans.configuration
    assert config.plans.key?(:free)
    assert_equal 0, config.plans[:free].price
  end

  def test_mixed_dsl_styles_inside_yielded_block
    PricingPlans.configure do |config|
      config.default_plan = :free

      # Bare
      plan :free do
        price 0
      end

      # Explicit via yielded param
      config.plan :pro do
        price 10
      end
    end

    cfg = PricingPlans.configuration
    assert cfg.plans.key?(:free)
    assert cfg.plans.key?(:pro)
    assert_equal 0, cfg.plans[:free].price
    assert_equal 10, cfg.plans[:pro].price
  end

  def test_arity_zero_block_uses_bare_dsl
    PricingPlans.configure do
      self.plan_owner_class = "Organization"
      self.default_plan = :free

      plan :free do
        price 0
      end
    end

    cfg = PricingPlans.configuration
    assert cfg.plans.key?(:free)
  end

  def test_period_cycle_validation
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.period_cycle = :billing_cycle

      config.plan :free do
        price 0
      end
    end

    assert_equal :billing_cycle, PricingPlans.configuration.period_cycle
  end

  def test_custom_period_cycle_callable
    custom_callable = ->(billable) { [Time.current, 1.day.from_now] }

    PricingPlans.configure do |config|
      config.default_plan = :free
      config.period_cycle = custom_callable

      config.plan :free do
        price 0
      end
    end

    assert_equal custom_callable, PricingPlans.configuration.period_cycle
  end
end
