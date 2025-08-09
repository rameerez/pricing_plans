# frozen_string_literal: true

require_relative "pricing_plans/version"
require_relative "pricing_plans/engine" if defined?(Rails::Engine)

module PricingPlans
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class PlanNotFoundError < Error; end
  class FeatureDenied < Error
    attr_reader :feature_key, :billable

    def initialize(message = nil, feature_key: nil, billable: nil)
      super(message)
      @feature_key = feature_key
      @billable = billable
    end
  end
  class InvalidOperation < Error; end

  autoload :Configuration, "pricing_plans/configuration"
  autoload :Registry, "pricing_plans/registry"
  autoload :Plan, "pricing_plans/plan"
  autoload :DSL, "pricing_plans/dsl"
  autoload :IntegerRefinements, "pricing_plans/integer_refinements"
  autoload :PlanResolver, "pricing_plans/plan_resolver"
  autoload :PaySupport, "pricing_plans/pay_support"
  autoload :LimitChecker, "pricing_plans/limit_checker"
  autoload :LimitableRegistry, "pricing_plans/limit_checker"
  autoload :GraceManager, "pricing_plans/grace_manager"
  autoload :PeriodCalculator, "pricing_plans/period_calculator"
  autoload :ControllerGuards, "pricing_plans/controller_guards"
  autoload :JobGuards, "pricing_plans/job_guards"
  autoload :ControllerRescues, "pricing_plans/controller_rescues"
  autoload :ViewHelpers, "pricing_plans/view_helpers"
  autoload :Limitable, "pricing_plans/limitable"
  autoload :Billable, "pricing_plans/billable"
  autoload :AssociationLimitRegistry, "pricing_plans/association_limit_registry"
  autoload :Result, "pricing_plans/result"
  autoload :OverageReporter, "pricing_plans/overage_reporter"
  autoload :RequestCache, "pricing_plans/request_cache"

  # Models
  autoload :EnforcementState, "pricing_plans/models/enforcement_state"
  autoload :Usage, "pricing_plans/models/usage"
  autoload :Assignment, "pricing_plans/models/assignment"

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure(&block)
      # Support both styles simultaneously inside the block:
      # - Bare DSL:   plan :free { ... }
      # - Explicit:   config.plan :free { ... }
      # We evaluate the block with self = configuration, while also
      # passing the configuration object as the first block parameter.
      # Evaluate with self = configuration and also pass the configuration
      # object as a block parameter for explicit calls (config.plan ...).
      configuration.instance_exec(configuration, &block) if block
      configuration.validate!
      Registry.build_from_configuration(configuration)
    end

    def reset_configuration!
      @configuration = nil
      Registry.clear!
      LimitableRegistry.clear!
      RequestCache.clear!
    end

    def registry
      Registry
    end
  end
end
