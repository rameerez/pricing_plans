# frozen_string_literal: true

require_relative "pricing_plans/version"
require_relative "pricing_plans/engine" if defined?(Rails::Engine)

module PricingPlans
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class PlanNotFoundError < Error; end
  class FeatureDenied < Error; end
  class InvalidOperation < Error; end
  
  autoload :Configuration, "pricing_plans/configuration"
  autoload :Registry, "pricing_plans/registry"
  autoload :Plan, "pricing_plans/plan" 
  autoload :DSL, "pricing_plans/dsl"
  autoload :IntegerRefinements, "pricing_plans/integer_refinements"
  autoload :PlanResolver, "pricing_plans/plan_resolver"
  autoload :LimitChecker, "pricing_plans/limit_checker"
  autoload :LimitableRegistry, "pricing_plans/limit_checker"
  autoload :GraceManager, "pricing_plans/grace_manager"
  autoload :PeriodCalculator, "pricing_plans/period_calculator"
  autoload :ControllerGuards, "pricing_plans/controller_guards"
  autoload :ViewHelpers, "pricing_plans/view_helpers"
  autoload :Limitable, "pricing_plans/limitable"
  autoload :Result, "pricing_plans/result"
  
  # Models
  autoload :EnforcementState, "pricing_plans/models/enforcement_state"
  autoload :Usage, "pricing_plans/models/usage"
  autoload :Assignment, "pricing_plans/models/assignment"
  
  class << self
    attr_writer :configuration
    
    def configuration
      @configuration ||= Configuration.new
    end
    
    def configure
      yield(configuration) if block_given?
      configuration.validate!
      Registry.build_from_configuration(configuration)
    end
    
    def reset_configuration!
      @configuration = nil
      Registry.clear!
      LimitableRegistry.clear!
    end
    
    def registry
      Registry
    end
  end
end
