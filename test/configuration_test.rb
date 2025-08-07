# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
  end

  def test_basic_configuration_setup
    PricingPlans.configure do |config|
      config.billable_class = "Organization"
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
    assert_equal "Organization", config.billable_class
    assert_equal :free, config.default_plan  
    assert_equal :pro, config.highlighted_plan
  end

  def test_requires_billable_class
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.default_plan = :free
      end
    end
    
    assert_match(/billable_class is required/, error.message)
  end

  def test_requires_default_plan
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.billable_class = "Organization"
      end
    end
    
    assert_match(/default_plan is required/, error.message)
  end

  def test_default_plan_must_be_defined
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.billable_class = "Organization"
        config.default_plan = :nonexistent
      end
    end
    
    assert_match(/default_plan nonexistent is not defined/, error.message)
  end

  def test_highlighted_plan_must_be_defined_if_set
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.configure do |config|
        config.billable_class = "Organization"
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
        config.billable_class = "Organization"
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
        config.billable_class = "Organization"
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
        config.billable_class = "Organization"
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
      config.billable_class = "Organization"
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
      config.billable_class = "Organization"
      config.default_plan = :free
      
      config.plan :free do
        price 0
      end
    end

    refute_nil PricingPlans.configuration.billable_class
    
    PricingPlans.reset_configuration!
    
    assert_nil PricingPlans.configuration.billable_class
  end

  def test_malformed_plan_blocks_handled
    error = assert_raises do
      PricingPlans.configure do |config|
        config.billable_class = "Organization" 
        config.default_plan = :free
        
        config.plan :free do
          raise "Something went wrong in plan block"
        end
      end
    end
    
    assert_match(/Something went wrong/, error.message)
  end

  def test_period_cycle_validation
    PricingPlans.configure do |config|
      config.billable_class = "Organization"
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
      config.billable_class = "Organization"
      config.default_plan = :free
      config.period_cycle = custom_callable
      
      config.plan :free do
        price 0
      end
    end

    assert_equal custom_callable, PricingPlans.configuration.period_cycle
  end
end