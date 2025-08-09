# frozen_string_literal: true

require_relative "dsl"

module PricingPlans
  class Configuration
    include DSL

    attr_accessor :default_plan, :highlighted_plan, :period_cycle
    # Optional ergonomics
    attr_accessor :default_cta_text, :default_cta_url, :auto_cta_with_pay
    # Global controller ergonomics
    # When a limit check blocks, controllers can redirect to a global default target.
    # Accepts:
    # - Symbol: a controller helper to call (e.g., :pricing_path)
    # - String: an absolute/relative path or full URL
    # - Proc: instance-exec'd in the controller (self is the controller). Signature: ->(result) { ... }
    #   Result contains: limit_key, billable, message, metadata
    attr_accessor :redirect_on_blocked_limit
    # Optional global message builder proc for human copy (i18n/hooks)
    # Signature suggestion: (context:, **kwargs) -> string
    # Contexts used: :over_limit, :grace, :feature_denied
    # Example kwargs: limit_key:, current_usage:, limit_amount:, grace_ends_at:, feature_key:, plan_name:
    attr_accessor :message_builder
    attr_reader :billable_class
    attr_reader :plans, :event_handlers

    def initialize
      @billable_class = nil
      @default_plan = nil
      @highlighted_plan = nil
      @period_cycle = :billing_cycle
      @default_cta_text = nil
      @default_cta_url = nil
      @auto_cta_with_pay = false
      @message_builder = nil
      @redirect_on_blocked_limit = nil
      @plans = {}
      @event_handlers = {
        warning: {},
        grace_start: {},
        block: {}
      }
    end

    def billable_class=(value)
      if value.nil?
        @billable_class = nil
        return
      end
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
      select_defaults_from_dsl!
      validate_required_settings!
      validate_plan_references!
      validate_dsl_markers!
      validate_plans!
    end
    def select_defaults_from_dsl!
      # If not explicitly configured, derive from any plan marked via DSL sugar
      if @default_plan.nil?
        dsl_default = @plans.values.find(&:default?)&.key
        @default_plan = dsl_default if dsl_default
      end

      if @highlighted_plan.nil?
        dsl_highlighted = @plans.values.find(&:highlighted?)&.key
        @highlighted_plan = dsl_highlighted if dsl_highlighted
      end
    end

    def validate_dsl_markers!
      defaults = @plans.values.select(&:default?)
      highlights = @plans.values.select(&:highlighted?)

      if defaults.size > 1
        keys = defaults.map(&:key).join(", ")
        raise PricingPlans::ConfigurationError, "Multiple plans marked default via DSL: #{keys}. Only one plan can be default."
      end

      if highlights.size > 1
        keys = highlights.map(&:key).join(", ")
        raise PricingPlans::ConfigurationError, "Multiple plans marked highlighted via DSL: #{keys}. Only one plan can be highlighted."
      end
    end

    private

    def validate_required_settings!
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
