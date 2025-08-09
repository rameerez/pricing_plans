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
  autoload :PricingViews, "pricing_plans/pricing_views"
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

    # Zero-shim Plans API for host apps
    # Returns an array of Plan objects in a sensible order (free → paid → enterprise/contact)
    def plans
      array = Registry.plans.values
      array.sort_by do |p|
        # Free first, then numeric price ascending, then price_string/stripe-price at the end
        if p.price && p.price.to_f.zero?
          0
        elsif p.price
          1 + p.price.to_f
        else
          10_000 # price_string or stripe_price (enterprise/contact) last
        end
      end
    end

    # One-call controller helper for dashboard pricing page
    # Returns OpenStruct with: plans, popular_plan_key, current_plan
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

    # One-call helper for marketing pages (no current plan)
    def for_marketing
      OpenStruct.new(
        plans: plans,
        popular_plan_key: (Registry.highlighted_plan&.key),
        current_plan: nil
      )
    end

    # Opinionated next-plan suggestion: pick the smallest plan that satisfies current usage
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

    # Optional view-model decorator for UIs
    def decorate_for_view(plan, context: :marketing, billable: nil, view: nil)
      is_current = billable ? (PlanResolver.effective_plan_for(billable)&.key == plan.key) : false
      is_popular = Registry.highlighted_plan&.key == plan.key
      name, price_label = ViewHelpers.instance_method(:plan_label).bind(Object.new.extend(ViewHelpers)).call(plan)
      {
        key: plan.key,
        name: name,
        description: plan.description,
        bullets: plan.bullets,
        price_label: price_label,
        is_current: is_current,
        is_popular: is_popular,
        button_text: plan.cta_text,
        button_url: plan.cta_url(view: view, billable: billable)
      }
    end

    # Drop-in partials entrypoints
    def render_pricing_cards(view:, context: :marketing, billable: nil)
      PricingViews.pricing_cards(view: view, context: context, billable: billable)
    end

    def render_usage_widget(view:, billable:, limits: [:products, :licenses, :activations])
      PricingViews.usage_widget(view: view, billable: billable, limits: limits)
    end

    def render_overage_banner(view:, billable:, limits: [:products, :licenses, :activations])
      PricingViews.overage_banner(view: view, billable: billable, limits: limits)
    end
  end
end
