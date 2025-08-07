# frozen_string_literal: true

require_relative "dsl"

module PricingPlans
  class Configuration
    include DSL
    
    attr_accessor :default_plan, :highlighted_plan, :period_cycle
    attr_reader :billable_class
    attr_reader :plans, :event_handlers
    
    def initialize
      @billable_class = nil
      @default_plan = nil
      @highlighted_plan = nil
      @period_cycle = :billing_cycle
      @plans = {}
      @event_handlers = {
        warning: {},
        grace_start: {},
        block: {}
      }
    end
    
    def billable_class=(value)
      unless value.is_a?(String) || value.is_a?(Class)
        raise PricingPlans::ConfigurationError, "billable_class must be a string or class"
      end
      @billable_class = value
    end
    
    def plan(key, &block)
      raise PricingPlans::ConfigurationError, "Plan key must be a symbol" unless key.is_a?(Symbol)
      raise PricingPlans::ConfigurationError, "Plan #{key} already defined" if @plans.key?(key)
      
      plan_instance = PricingPlans::Plan.new(key)
      plan_instance.instance_eval(&block)
      @plans[key] = plan_instance
    end
    
    def on_warning(limit_key, &block)
      raise PricingPlans::ConfigurationError, "Block required for on_warning" unless block_given?
      @event_handlers[:warning][limit_key] = block
    end
    
    def on_grace_start(limit_key, &block)
      raise PricingPlans::ConfigurationError, "Block required for on_grace_start" unless block_given?
      @event_handlers[:grace_start][limit_key] = block
    end
    
    def on_block(limit_key, &block)
      raise PricingPlans::ConfigurationError, "Block required for on_block" unless block_given?
      @event_handlers[:block][limit_key] = block
    end
    
    def validate!
      validate_required_settings!
      validate_plan_references!
      validate_plans!
    end
    
    private
    
    def validate_required_settings!
      raise PricingPlans::ConfigurationError, "billable_class is required" unless @billable_class
      raise PricingPlans::ConfigurationError, "default_plan is required" unless @default_plan
    end
    
    def validate_plan_references!
      unless @plans.key?(@default_plan)
        raise PricingPlans::ConfigurationError, "default_plan #{@default_plan} is not defined"
      end
      
      if @highlighted_plan && !@plans.key?(@highlighted_plan)
        raise PricingPlans::ConfigurationError, "highlighted_plan #{@highlighted_plan} is not defined"
      end
    end
    
    def validate_plans!
      @plans.each_value(&:validate!)
    end
  end
end