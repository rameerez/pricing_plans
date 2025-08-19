# frozen_string_literal: true

require_relative "dsl"

module PricingPlans
  class Configuration
    include DSL

    attr_accessor :default_plan, :highlighted_plan, :period_cycle
    # Optional ergonomics
    attr_accessor :default_cta_text, :default_cta_url
    # Global controller ergonomics
      # Optional global resolver for controller plan owner. Per-controller settings still win.
      # Accepts:
      # - Symbol: a controller helper to call (e.g., :current_organization)
      # - Proc: instance-exec'd in the controller (self is the controller)
      attr_reader :controller_plan_owner_method, :controller_plan_owner_proc
    # When a limit check blocks, controllers can redirect to a global default target.
    # Accepts:
    # - Symbol: a controller helper to call (e.g., :pricing_path)
    # - String: an absolute/relative path or full URL
    # - Proc: instance-exec'd in the controller (self is the controller). Signature: ->(result) { ... }
    #   Result contains: limit_key, plan_owner, message, metadata
    attr_accessor :redirect_on_blocked_limit
    # Optional global message builder proc for human copy (i18n/hooks)
    # Signature suggestion: (context:, **kwargs) -> string
    # Contexts used: :over_limit, :grace, :feature_denied
    # Example kwargs: limit_key:, current_usage:, limit_amount:, grace_ends_at:, feature_key:, plan_name:
    attr_accessor :message_builder
    attr_reader :plan_owner_class
    # Optional: custom resolver for displaying price labels from processor
    # Signature: ->(plan) { "${amount}/mo" }
    attr_accessor :price_label_resolver
    # Auto-fetch price labels from processor when possible (Stripe via stripe-ruby)
    attr_accessor :auto_price_labels_from_processor
    # Semantic pricing components resolver hook: ->(plan, interval) { PriceComponents | nil }
    attr_accessor :price_components_resolver
    # Default currency symbol when Stripe isn't available
    attr_accessor :default_currency_symbol
    # Cache for Stripe prices. Defaults to in-memory store if nil. Should respond to read/write with ttl.
    attr_accessor :price_cache
    # Seconds for cache TTL for Stripe lookups
    attr_accessor :price_cache_ttl
    # Optional free caption copy (UI copy holder)
    attr_accessor :free_price_caption
    # Optional default interval for UI toggles
    attr_accessor :interval_default_for_ui
    # Optional downgrade policy hook for CTA ergonomics
    # Signature: ->(from:, to:, plan_owner:) { [allowed_boolean, reason_string_or_nil] }
    attr_accessor :downgrade_policy
    attr_reader :plans, :event_handlers

    def initialize
      @plan_owner_class = nil
      @default_plan = nil
      @highlighted_plan = nil
      @period_cycle = :billing_cycle
      @default_cta_text = nil
      @default_cta_url = nil
      @message_builder = nil
      @controller_plan_owner_method = nil
      @controller_plan_owner_proc = nil
      @redirect_on_blocked_limit = nil
      @price_label_resolver = nil
      @auto_price_labels_from_processor = true
      @price_components_resolver = nil
      @default_currency_symbol = "$"
      @price_cache = (defined?(Rails) && Rails.respond_to?(:cache)) ? Rails.cache : nil
      @price_cache_ttl = 600 # 10 minutes
      @free_price_caption = "Forever free"
      @interval_default_for_ui = :month
      @downgrade_policy = ->(from:, to:, plan_owner:) { [true, nil] }
      @plans = {}
      @event_handlers = {
        warning: {},
        grace_start: {},
        block: {}
      }
    end

    def plan_owner_class=(value)
      if value.nil?
        @plan_owner_class = nil
        return
      end
      unless value.is_a?(String) || value.is_a?(Class)
        raise PricingPlans::ConfigurationError, "plan_owner_class must be a string or class"
      end
      @plan_owner_class = value
    end

    def plan(key, &block)
      raise PricingPlans::ConfigurationError, "Plan key must be a symbol" unless key.is_a?(Symbol)
      raise PricingPlans::ConfigurationError, "Plan #{key} already defined" if @plans.key?(key)

      plan_instance = PricingPlans::Plan.new(key)
      plan_instance.instance_eval(&block)
      @plans[key] = plan_instance
    end


      # Global controller plan owner resolver API
      # Usage:
      #   config.controller_plan_owner :current_organization
      #   # or
      #   config.controller_plan_owner { current_account }
      def controller_plan_owner(method_name = nil, &block)
        if method_name
          @controller_plan_owner_method = method_name.to_sym
          @controller_plan_owner_proc = nil
        elsif block_given?
          @controller_plan_owner_proc = block
          @controller_plan_owner_method = nil
        else
          @controller_plan_owner_method
        end
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
