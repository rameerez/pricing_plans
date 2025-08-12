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
  autoload :Limitable, "pricing_plans/limitable"
  autoload :Billable, "pricing_plans/billable"
  autoload :AssociationLimitRegistry, "pricing_plans/association_limit_registry"
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

    # Single, UI-neutral helper for pricing pages.
    # Returns an array of Hashes containing plain data for building pricing UIs.
    # Each item includes: :key, :name, :description, :bullets, :price_label,
    # :is_current, :is_popular, :button_text, :button_url
    def for_pricing(billable: nil, view: nil)
      plans.map { |plan| decorate_for_view(plan, billable: billable, view: view) }
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

    # Optional view-model decorator for UIs (pure data, no HTML)
    def decorate_for_view(plan, billable: nil, view: nil)
      is_current = billable ? (PlanResolver.effective_plan_for(billable)&.key == plan.key) : false
      is_popular = Registry.highlighted_plan&.key == plan.key
      price_label = plan_price_label_for(plan)
      {
        key: plan.key,
        name: plan.name,
        description: plan.description,
        bullets: plan.bullets,
        price_label: price_label,
        is_current: is_current,
        is_popular: is_popular,
        button_text: plan.cta_text,
        button_url: plan.cta_url(billable: billable)
      }
    end

    # Derive a human price label for a plan
    def plan_price_label_for(plan)
      return "Free" if plan.price && plan.price.to_i.zero?
      return plan.price_string if plan.price_string
      return "$#{plan.price}/mo" if plan.price
      return "Contact" if plan.stripe_price || plan.price.nil?
      nil
    end

    # UI-neutral status helpers for building settings/usage UIs
    def limit_status(limit_key, billable:)
      plan = PlanResolver.effective_plan_for(billable)
      limit_config = plan&.limit_for(limit_key)
      return { configured: false } unless limit_config

      usage = LimitChecker.current_usage_for(billable, limit_key, limit_config)
      limit_amount = limit_config[:to]
      percent = LimitChecker.plan_limit_percent_used(billable, limit_key)
      grace = GraceManager.grace_active?(billable, limit_key)
      blocked = GraceManager.should_block?(billable, limit_key)

      {
        configured: true,
        limit_key: limit_key.to_sym,
        limit_amount: limit_amount,
        current_usage: usage,
        percent_used: percent,
        grace_active: grace,
        grace_ends_at: GraceManager.grace_ends_at(billable, limit_key),
        blocked: blocked,
        after_limit: limit_config[:after_limit],
        per: !!limit_config[:per]
      }
    end

    def limit_statuses(*limit_keys, billable:)
      keys = limit_keys.flatten
      keys.index_with { |k| limit_status(k, billable: billable) }
    end

    StatusItem = Struct.new(:key, :current, :allowed, :percent_used, :grace_active, :grace_ends_at, :blocked, :per, keyword_init: true)

    def status(billable, limits: [])
      Array(limits).map do |limit_key|
        st = limit_status(limit_key, billable: billable)
        unless st[:configured]
          StatusItem.new(key: limit_key, current: 0, allowed: nil, percent_used: 0.0, grace_active: false, grace_ends_at: nil, blocked: false, per: false)
        else
          StatusItem.new(
            key: limit_key,
            current: st[:current_usage],
            allowed: st[:limit_amount],
            percent_used: st[:percent_used],
            grace_active: st[:grace_active],
            grace_ends_at: st[:grace_ends_at],
            blocked: st[:blocked],
            per: st[:per]
          )
        end
      end
    end

    # Aggregates across multiple limits for global banners/messages
    # Returns one of :ok, :warning, :grace, :blocked
    def highest_severity_for(billable, *limit_keys)
      keys = limit_keys.flatten
      severities = keys.map do |key|
        st = limit_status(key, billable: billable)
        next :ok unless st[:configured]
        if st[:blocked]
          lim = st[:limit_amount]
          cur = st[:current_usage]
          return :blocked if lim != :unlimited && lim.to_i > 0 && cur.to_i >= lim.to_i
        end
        return :grace if st[:grace_active]
        percent = st[:percent_used].to_f
        warn_thresholds = LimitChecker.warning_thresholds(billable, key)
        highest_warn = warn_thresholds.max.to_f * 100.0
        (percent >= highest_warn && highest_warn.positive?) ? :warning : :ok
      end
      severities.include?(:warning) ? :warning : :ok
    end

    # Combine human messages for a set of limits into one string
    def combine_messages_for(billable, *limit_keys)
      keys = limit_keys.flatten
      parts = keys.map do |key|
        result = ControllerGuards.require_plan_limit!(key, billable: billable, by: 0)
        next nil if result.ok?
        "#{key.to_s.humanize}: #{result.message}"
      end.compact
      return nil if parts.empty?
      parts.join(" · ")
    end

    # Convenience: severity for a single limit key
    # Returns :ok | :warning | :grace | :blocked
    def severity_for(billable, limit_key)
      highest_severity_for(billable, limit_key)
    end

    # Convenience: message for a single limit key, or nil if OK
    def message_for(billable, limit_key)
      result = ControllerGuards.require_plan_limit!(limit_key, billable: billable, by: 0)
      result.ok? ? nil : result.message
    end

    # Compute how much over the limit the billable is for a key (0 if within)
    def overage_for(billable, limit_key)
      st = limit_status(limit_key, billable: billable)
      return 0 unless st[:configured]
      allowed = st[:limit_amount]
      current = st[:current_usage].to_i
      return 0 unless allowed.is_a?(Numeric)
      [current - allowed.to_i, 0].max
    end

    # Boolean: any attention required (warning/grace/blocked) for provided keys
    def attention_required?(billable, *limit_keys)
      highest_severity_for(billable, *limit_keys) != :ok
    end

    # Boolean: approaching a limit. If `at:` given, uses that numeric threshold (0..1);
    # otherwise uses the highest configured warn_at threshold for the limit.
    def approaching_limit?(billable, limit_key, at: nil)
      st = limit_status(limit_key, billable: billable)
      return false unless st[:configured]
      percent = st[:percent_used].to_f
      threshold = if at
        (at.to_f * 100.0)
      else
        thresholds = LimitChecker.warning_thresholds(billable, limit_key)
        thresholds.max.to_f * 100.0
      end
      return false if threshold <= 0.0
      percent >= threshold
    end

    # Recommend CTA data (pure data, no UI): { text:, url: }
    # Resolves plan-level CTA first, then global defaults; returns nil fields when unknown
    def cta_for(billable)
      plan = PlanResolver.effective_plan_for(billable)
      cfg = configuration
      url = plan&.cta_url(billable: billable) || cfg.default_cta_url
      text = plan&.cta_text || cfg.default_cta_text
      { text: text, url: url }
    end
  end
end
