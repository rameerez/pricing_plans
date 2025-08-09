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
  autoload :PlanResolver, "pricing_plans/plan_resolver"
  autoload :PaySupport, "pricing_plans/pay_support"
  autoload :LimitChecker, "pricing_plans/limit_checker"
  autoload :LimitableRegistry, "pricing_plans/limit_checker"
  autoload :GraceManager, "pricing_plans/grace_manager"
  autoload :PeriodCalculator, "pricing_plans/period_calculator"
  autoload :ControllerGuards, "pricing_plans/controller_guards"
  autoload :JobGuards, "pricing_plans/job_guards"
  autoload :ViewHelpers, "pricing_plans/view_helpers"
  autoload :Limitable, "pricing_plans/limitable"
  autoload :Billable, "pricing_plans/billable"
  autoload :Result, "pricing_plans/result"
  autoload :OverageReporter, "pricing_plans/overage_reporter"
  
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
      configuration.instance_exec(configuration, &block) if block
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

    def plans
      array = Registry.plans.values
      array.sort_by do |p|
        if p.price && p.price.to_f.zero?
          0
        elsif p.price
          1 + p.price.to_f
        else
          10_000
        end
      end
    end

    def for_dashboard(billable)
      OpenStruct.new(
        plans: plans,
        popular_plan_key: (Registry.highlighted_plan&.key),
        current_plan: begin
          PlanResolver.effective_plan_for(billable)
        rescue StandardError
          nil
        end
      )
    end

    def for_marketing
      OpenStruct.new(
        plans: plans,
        popular_plan_key: (Registry.highlighted_plan&.key),
        current_plan: nil
      )
    end

    def suggest_next_plan_for(billable, keys: nil)
      current_plan = PlanResolver.effective_plan_for(billable)
      sorted = plans
      keys ||= (current_plan&.limits&.keys || [])
      keys = keys.map(&:to_sym)

      candidate = sorted.find do |plan|
        if current_plan && current_plan.price && plan.price && plan.price.to_f < current_plan.price.to_f
          next false
        end
        keys.all? do |key|
          limit = plan.limit_for(key)
          next true unless limit
          limit[:to] == :unlimited || LimitChecker.current_usage_for(billable, key, limit) <= limit[:to].to_i
        end
      end
      candidate || current_plan || Registry.default_plan
    end
  end
end
