# frozen_string_literal: true

require_relative "pricing_plans/version"
require_relative "pricing_plans/engine" if defined?(Rails::Engine)

module PricingPlans
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class PlanNotFoundError < Error; end
  class FeatureDenied < Error
    attr_reader :feature_key, :plan_owner

    def initialize(message = nil, feature_key: nil, plan_owner: nil)
      super(message)
      @feature_key = feature_key
      @plan_owner = plan_owner
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
  autoload :PlanOwner, "pricing_plans/plan_owner"
  autoload :AssociationLimitRegistry, "pricing_plans/association_limit_registry"
  autoload :Result, "pricing_plans/result"
  autoload :OverageReporter, "pricing_plans/overage_reporter"
  autoload :PriceComponents, "pricing_plans/price_components"
  autoload :ViewHelpers, "pricing_plans/view_helpers"

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
    def for_pricing(plan_owner: nil, view: nil)
      plans.map { |plan| decorate_for_view(plan, plan_owner: plan_owner, view: view) }
    end

    # View model for modern UIs (Stimulus/Hotwire/JSON). Pure data.
    # Uses the new semantic pricing API on Plan (price_components and Stripe accessors).
    def view_models
      plans.map { |p| p.to_view_model }
    end

    # Opinionated next-plan suggestion: pick the smallest plan that satisfies current usage
    def suggest_next_plan_for(plan_owner, keys: nil)
      current_plan = PlanResolver.effective_plan_for(plan_owner)
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
          limit[:to] == :unlimited || LimitChecker.current_usage_for(plan_owner, key, limit) <= limit[:to].to_i
        end
      end
      candidate || current_plan || Registry.default_plan
    end

    # Optional view-model decorator for UIs (pure data, no HTML)
    def decorate_for_view(plan, plan_owner: nil, view: nil)
      is_current = plan_owner ? (PlanResolver.effective_plan_for(plan_owner)&.key == plan.key) : false
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
        button_url: plan.cta_url(plan_owner: plan_owner)
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
    def limit_status(limit_key, plan_owner:)
      plan = PlanResolver.effective_plan_for(plan_owner)
      limit_config = plan&.limit_for(limit_key)
      return { configured: false } unless limit_config

      usage = LimitChecker.current_usage_for(plan_owner, limit_key, limit_config)
      limit_amount = limit_config[:to]
      percent = LimitChecker.plan_limit_percent_used(plan_owner, limit_key)
      grace = GraceManager.grace_active?(plan_owner, limit_key)
      blocked = GraceManager.should_block?(plan_owner, limit_key)

      {
        configured: true,
        limit_key: limit_key.to_sym,
        limit_amount: limit_amount,
        current_usage: usage,
        percent_used: percent,
        grace_active: grace,
        grace_ends_at: GraceManager.grace_ends_at(plan_owner, limit_key),
        blocked: blocked,
        after_limit: limit_config[:after_limit],
        per: !!limit_config[:per]
      }
    end

    def limit_statuses(*limit_keys, plan_owner:)
      keys = limit_keys.flatten
      keys.index_with { |k| limit_status(k, plan_owner: plan_owner) }
    end

    # Unified, pure-data status item for a single limit key
    # Includes raw usage, gating flags, and view-friendly severity/message
    StatusItem = Struct.new(
      :key,
      :human_key,
      :current,
      :allowed,
      :percent_used,
      :grace_active,
      :grace_ends_at,
      :blocked,
      :per,
      :severity,
      :severity_level,
      :message,
      :overage,
      :configured,
      :unlimited,
      :remaining,
      :after_limit,
      :attention?,
      :next_creation_blocked?,
      :warn_thresholds,
      :next_warn_percent,
      :period_start,
      :period_end,
      :period_seconds_remaining,
      keyword_init: true
    )

    def status(plan_owner, limits: [])
      items = Array(limits).map do |limit_key|
        st = limit_status(limit_key, plan_owner: plan_owner)
        if !st[:configured]
          StatusItem.new(
            key: limit_key,
            human_key: limit_key.to_s.humanize.downcase,
            current: 0,
            allowed: nil,
            percent_used: 0.0,
            grace_active: false,
            grace_ends_at: nil,
            blocked: false,
            per: false,
            severity: :ok,
            severity_level: 0,
            message: nil,
            overage: 0,
            configured: false,
            unlimited: false,
            remaining: nil,
            after_limit: nil,
            attention?: false,
            next_creation_blocked?: false,
            warn_thresholds: [],
            next_warn_percent: nil,
            period_start: nil,
            period_end: nil,
            period_seconds_remaining: nil
          )
        else
          sev = severity_for(plan_owner, limit_key)
          allowed = st[:limit_amount]
          current = st[:current_usage].to_i
          unlimited = (allowed == :unlimited)
          remaining = if allowed.is_a?(Numeric)
            [allowed.to_i - current, 0].max
          else
            nil
          end
          warn_thresholds = LimitChecker.warning_thresholds(plan_owner, limit_key)
          percent = st[:percent_used].to_f
          next_warn = begin
            thresholds = warn_thresholds.map { |t| t.to_f * 100.0 }.uniq.sort
            thresholds.find { |t| t > percent }
          end
          period_start = nil
          period_end = nil
          period_seconds_remaining = nil
          if st[:per]
            begin
              period_start, period_end = PeriodCalculator.window_for(plan_owner, limit_key)
              if period_end
                period_seconds_remaining = [0, (period_end - Time.current).to_i].max
              end
            rescue StandardError
              # ignore period window resolution errors in status
            end
          end
          next_creation_blocked = case sev
          when :blocked
            true
          when :at_limit
            st[:after_limit] == :block_usage
          else
            false
          end
          StatusItem.new(
            key: limit_key,
            human_key: limit_key.to_s.humanize.downcase,
            current: current,
            allowed: allowed,
            percent_used: st[:percent_used],
            grace_active: st[:grace_active],
            grace_ends_at: st[:grace_ends_at],
            blocked: st[:blocked],
            per: st[:per],
            severity: sev,
            severity_level: case sev
                             when :ok then 0
                             when :warning then 1
                             when :at_limit then 2
                             when :grace then 3
                             when :blocked then 4
                             else 0
                             end,
            message: (sev == :ok ? nil : message_for(plan_owner, limit_key)),
            overage: overage_for(plan_owner, limit_key),
            configured: true,
            unlimited: unlimited,
            remaining: remaining,
            after_limit: st[:after_limit],
            attention?: sev != :ok,
            next_creation_blocked?: next_creation_blocked,
            warn_thresholds: warn_thresholds,
            next_warn_percent: next_warn,
            period_start: period_start,
            period_end: period_end,
            period_seconds_remaining: period_seconds_remaining
          )
        end
      end

      # Compute and attach overall helpers directly on the returned array
      keys = items.map(&:key)
      sev = highest_severity_for(plan_owner, *keys)
      title = summary_title_for(sev)
      msg = summary_message_for(plan_owner, *keys, severity: sev)
      highest_keys = keys.select { |k| severity_for(plan_owner, k) == sev }
      highest_limits = items.select { |it| highest_keys.include?(it.key) }
      human_keys = highest_keys.map { |k| k.to_s.humanize.downcase }
      keys_sentence = if human_keys.respond_to?(:to_sentence)
        human_keys.to_sentence
      else
        human_keys.length <= 2 ? human_keys.join(" and ") : (human_keys[0..-2].join(", ") + " and " + human_keys[-1])
      end
      noun = highest_keys.size == 1 ? "plan limit" : "plan limits"
      has_have = highest_keys.size == 1 ? "has" : "have"
      cta = cta_for_upgrade(plan_owner)

      sev_level = case sev
                  when :ok then 0
                  when :warning then 1
                  when :at_limit then 2
                  when :grace then 3
                  when :blocked then 4
                  else 0
                  end

      items.define_singleton_method(:overall_severity) { sev }
      items.define_singleton_method(:overall_severity_level) { sev_level }
      items.define_singleton_method(:overall_title) { title }
      items.define_singleton_method(:overall_message) { msg }
      items.define_singleton_method(:overall_attention?) { sev != :ok }
      items.define_singleton_method(:overall_keys) { keys }
      items.define_singleton_method(:overall_highest_keys) { highest_keys }
      items.define_singleton_method(:overall_highest_limits) { highest_limits }
      items.define_singleton_method(:overall_keys_sentence) { keys_sentence }
      items.define_singleton_method(:overall_noun) { noun }
      items.define_singleton_method(:overall_has_have) { has_have }
      items.define_singleton_method(:overall_cta_text) { cta[:text] }
      items.define_singleton_method(:overall_cta_url) { cta[:url] }

      items
    end

    # Aggregates across multiple limits for global banners/messages
    # Returns one of :ok, :warning, :at_limit, :grace, :blocked
    def highest_severity_for(plan_owner, *limit_keys)
      keys = limit_keys.flatten
      per_key = keys.map do |key|
        st = limit_status(key, plan_owner: plan_owner)
        next :ok unless st[:configured]

        lim = st[:limit_amount]
        cur = st[:current_usage]

        # Grace has priority over other non-blocked statuses
        return :grace if st[:grace_active]

        # Numeric limit semantics
        if lim != :unlimited && lim.to_i > 0
          return :blocked if cur.to_i > lim.to_i
          return :at_limit if cur.to_i == lim.to_i
        end

        # Otherwise, warning based on thresholds
        percent = st[:percent_used].to_f
        warn_thresholds = LimitChecker.warning_thresholds(plan_owner, key)
        highest_warn = warn_thresholds.max.to_f * 100.0
        (percent >= highest_warn && highest_warn.positive?) ? :warning : :ok
      end
      return :at_limit if per_key.include?(:at_limit)
      per_key.include?(:warning) ? :warning : :ok
    end

    # Global overview for multiple keys for easy banner building.
    # Returns: { severity:, severity_level:, title:, message:, attention?:, keys:, highest_keys:, highest_limits:, keys_sentence:, noun:, has_have:, cta_text:, cta_url: }
    def overview_for(plan_owner, *limit_keys)
      keys = limit_keys.flatten
      items = status(plan_owner, limits: keys)
      {
        severity: items.overall_severity,
        severity_level: items.overall_severity_level,
        title: items.overall_title,
        message: items.overall_message,
        attention?: items.overall_attention?,
        keys: items.overall_keys,
        highest_keys: items.overall_highest_keys,
        highest_limits: items.overall_highest_limits,
        keys_sentence: items.overall_keys_sentence,
        noun: items.overall_noun,
        has_have: items.overall_has_have,
        cta_text: items.overall_cta_text,
        cta_url: items.overall_cta_url
      }
    end

    # Human title for overall banner based on severity
    def summary_title_for(severity)
      case severity
      when :blocked then "Plan limit reached"
      when :grace   then "Over limit — grace active"
      when :at_limit then "At your plan limit"
      when :warning then "Approaching plan limit"
      else "All good"
      end
    end

    # Short, humanized summary for multiple keys
    # Builds copy using only the keys at the highest severity
    def summary_message_for(plan_owner, *limit_keys, severity: nil)
      keys = limit_keys.flatten
      return nil if keys.empty?
      sev = severity || highest_severity_for(plan_owner, *keys)
      return nil if sev == :ok

      affected = keys.select { |k| severity_for(plan_owner, k) == sev }
      human_keys = affected.map { |k| k.to_s.humanize.downcase }
      keys_list = if human_keys.respond_to?(:to_sentence)
        human_keys.to_sentence
      else
        # Simple fallback: "a, b and c"
        if human_keys.length <= 2
          human_keys.join(" and ")
        else
          human_keys[0..-2].join(", ") + " and " + human_keys[-1]
        end
      end
      noun = affected.size == 1 ? "plan limit" : "plan limits"

      case sev
      when :blocked
        "Your #{noun} for #{keys_list} #{affected.size == 1 ? "has" : "have"} been exceeded. Please upgrade to continue."
      when :grace
        # If any grace ends_at is present, show the earliest
        grace_end = keys.map { |k| GraceManager.grace_ends_at(plan_owner, k) }.compact.min
        suffix = grace_end ? ", grace active until #{grace_end}" : ""
        "You are over your #{noun} for #{keys_list}#{suffix}. Please upgrade to avoid service disruption."
      when :at_limit
        "You have reached your #{noun} for #{keys_list}."
      else # :warning
        "You are approaching your #{noun} for #{keys_list}."
      end
    end

    # Combine human messages for a set of limits into one string
    def combine_messages_for(plan_owner, *limit_keys)
      keys = limit_keys.flatten
      parts = keys.map do |key|
        result = ControllerGuards.require_plan_limit!(key, plan_owner: plan_owner, by: 0)
        next nil if result.ok?
        "#{key.to_s.humanize}: #{result.message}"
      end.compact
      return nil if parts.empty?
      parts.join(" · ")
    end

    # Convenience: severity for a single limit key
    # Returns :ok | :warning | :grace | :blocked
    def severity_for(plan_owner, limit_key)
      highest_severity_for(plan_owner, limit_key)
    end

    # Convenience: message for a single limit key, or nil if OK
    def message_for(plan_owner, limit_key)
      st = limit_status(limit_key, plan_owner: plan_owner)
      return nil unless st[:configured]

      sev = severity_for(plan_owner, limit_key)
      return nil if sev == :ok

      cfg = configuration
      key = limit_key
      cur = st[:current_usage]
      lim = st[:limit_amount]
      grace_ends = st[:grace_ends_at]

      if cfg.message_builder
        context = case sev
                  when :blocked then :over_limit
                  when :grace   then :grace
                  when :at_limit then :at_limit
                  else :warning
                  end
        begin
          return cfg.message_builder.call(context: context, limit_key: key, current_usage: cur, limit_amount: lim, grace_ends_at: grace_ends)
        rescue StandardError
          # fall through to defaults
        end
      end

      noun = PricingPlans.noun_for(key) rescue "limit"

      # Defaults
      case sev
      when :blocked
        if lim.is_a?(Numeric)
          "You've gone over your #{noun} for #{key.to_s.humanize.downcase} (#{cur}/#{lim}). Please upgrade your plan."
        else
          "You've gone over your #{noun} for #{key.to_s.humanize.downcase}. Please upgrade your plan."
        end
      when :grace
        deadline = grace_ends ? ", and your grace period ends #{grace_ends.strftime('%B %d at %I:%M%p')}" : ""
        if lim.is_a?(Numeric)
          "Heads up! You’re currently over your #{noun} for #{key.to_s.humanize.downcase} (#{cur}/#{lim})#{deadline}. Please upgrade soon to avoid any interruptions."
        else
          "Heads up! You’re currently over your #{noun} for #{key.to_s.humanize.downcase}#{deadline}. Please upgrade soon to avoid any interruptions."
        end
      when :at_limit
        if lim.is_a?(Numeric)
          "You’ve reached your #{noun} for #{key.to_s.humanize.downcase} (#{cur}/#{lim}). Upgrade your plan to unlock more."
        else
          "You’re at the maximum allowed for #{key.to_s.humanize.downcase}. Want more? Consider upgrading your plan."
        end
      else # :warning
        if lim.is_a?(Numeric)
          "You’re getting close to your #{noun} for #{key.to_s.humanize.downcase} (#{cur}/#{lim}). Keep an eye on your usage, or upgrade your plan now to stay ahead."
        else
          "You’re getting close to your #{noun} for #{key.to_s.humanize.downcase}. Keep an eye on your usage, or upgrade your plan now to stay ahead."
        end
      end
      end

    # Compute how much over the limit the plan_owner is for a key (0 if within)
    def overage_for(plan_owner, limit_key)
      st = limit_status(limit_key, plan_owner: plan_owner)
      return 0 unless st[:configured]
      allowed = st[:limit_amount]
      current = st[:current_usage].to_i
      return 0 unless allowed.is_a?(Numeric)
      [current - allowed.to_i, 0].max
    end

    # Boolean: any attention required (warning/grace/blocked) for provided keys
    def attention_required?(plan_owner, *limit_keys)
      highest_severity_for(plan_owner, *limit_keys) != :ok
    end

    # Boolean: approaching a limit. If `at:` given, uses that numeric threshold (0..1);
    # otherwise uses the highest configured warn_at threshold for the limit.
    def approaching_limit?(plan_owner, limit_key, at: nil)
      st = limit_status(limit_key, plan_owner: plan_owner)
      return false unless st[:configured]
      percent = st[:percent_used].to_f
      threshold = if at
        (at.to_f * 100.0)
      else
        thresholds = LimitChecker.warning_thresholds(plan_owner, limit_key)
        thresholds.max.to_f * 100.0
      end
      return false if threshold <= 0.0
      percent >= threshold
    end

    # Recommend CTA data (pure data, no UI): { text:, url: }
    # For limit banners, prefer global upgrade defaults to avoid confusing “Current Plan” CTAs
    def cta_for_upgrade(plan_owner)
      cfg = configuration
      url = cfg.default_cta_url
      url ||= (cfg.redirect_on_blocked_limit.is_a?(String) ? cfg.redirect_on_blocked_limit : nil)
      text = cfg.default_cta_text.presence || "View Plans"
      { text: text, url: url }
    end

    # Recommend CTA data used by other contexts (pricing plan cards etc.)
    def cta_for(plan_owner)
      plan = PlanResolver.effective_plan_for(plan_owner)
      cfg = configuration
      url = plan&.cta_url(plan_owner: plan_owner) || cfg.default_cta_url
      if url.nil? && cfg.redirect_on_blocked_limit.is_a?(String)
        url = cfg.redirect_on_blocked_limit
      end
      text = plan&.cta_text || cfg.default_cta_text
      { text: text, url: url }
    end

    # Pure-data alert view model for a single limit key. No HTML.
    # Returns keys: :visible? (boolean), :severity, :title, :message, :overage, :cta_text, :cta_url
    def alert_for(plan_owner, limit_key)
      sev = severity_for(plan_owner, limit_key)
      return { visible?: false, severity: :ok } if sev == :ok

      msg = message_for(plan_owner, limit_key)
      over = overage_for(plan_owner, limit_key)
      cta  = cta_for_upgrade(plan_owner)
      titles = {
        warning: "Approaching Limit",
        at_limit: "You've reached your #{limit_key.to_s.humanize.downcase} limit",
        grace:   "Limit for #{limit_key.to_s.humanize.downcase} exceeded (in grace period)",
        blocked: "Cannot create more #{limit_key.to_s.humanize.downcase}"
      }
      {
        visible?: true,
        severity: sev,
        title: titles[sev] || sev.to_s.humanize,
        message: msg,
        overage: over,
        cta_text: cta[:text],
        cta_url: cta[:url]
      }
    end

    # Global highlighted/popular plan sugar (UI ergonomics)
    def highlighted_plan
      Registry.highlighted_plan
    end

    def highlighted_plan_key
      highlighted_plan&.key
    end

    def popular_plan
      highlighted_plan
    end

    def popular_plan_key
      highlighted_plan_key
    end
  end
end
