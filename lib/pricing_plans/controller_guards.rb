# frozen_string_literal: true

module PricingPlans
  module ControllerGuards
    extend self

    def require_plan_limit!(limit_key, billable:, by: 1, allow_system_override: false)
      plan = PlanResolver.effective_plan_for(billable)
      limit_config = plan&.limit_for(limit_key)
      return Result.within("No limit configured for #{limit_key}") unless limit_config
      return Result.within("Unlimited #{limit_key}") if limit_config[:to] == :unlimited

      current_usage = LimitChecker.current_usage_for(billable, limit_key, limit_config)
      limit_amount = limit_config[:to]
      remaining = limit_amount - current_usage
      would_exceed = remaining < by

      if would_exceed
        if allow_system_override
          metadata = build_metadata(billable, limit_key, current_usage, limit_amount)
          return Result.new(state: :blocked, message: build_over_limit_message(limit_key, current_usage, limit_amount, :blocked), limit_key: limit_key, billable: billable, metadata: metadata.merge(system_override: true))
        end
        case limit_config[:after_limit]
        when :just_warn
          handle_warning_only(billable, limit_key, current_usage, limit_amount)
        when :block_usage
          GraceManager.mark_blocked!(billable, limit_key)
          Result.blocked(build_over_limit_message(limit_key, current_usage, limit_amount, :blocked), limit_key: limit_key, billable: billable, metadata: build_metadata(billable, limit_key, current_usage, limit_amount))
        when :grace_then_block
          if GraceManager.should_block?(billable, limit_key)
            GraceManager.mark_blocked!(billable, limit_key)
            Result.blocked(build_over_limit_message(limit_key, current_usage, limit_amount, :blocked), limit_key: limit_key, billable: billable, metadata: build_metadata(billable, limit_key, current_usage, limit_amount))
          else
            GraceManager.mark_exceeded!(billable, limit_key, grace_period: limit_config[:grace]) unless GraceManager.grace_active?(billable, limit_key)
            ends_at = GraceManager.grace_ends_at(billable, limit_key)
            Result.grace(build_grace_message(limit_key, current_usage, limit_amount, ends_at), limit_key: limit_key, billable: billable, metadata: build_metadata(billable, limit_key, current_usage, limit_amount, grace_ends_at: ends_at))
          end
        else
          Result.blocked("Unknown after_limit policy: #{limit_config[:after_limit]}")
        end
      else
        percent_after = ((current_usage + by).to_f / limit_amount) * 100
        thresholds = LimitChecker.warning_thresholds(billable, limit_key)
        crossed = thresholds.find do |t|
          threshold_percent = t * 100
          current_percent = (current_usage.to_f / limit_amount) * 100
          current_percent < threshold_percent && percent_after >= threshold_percent
        end
        if crossed
          GraceManager.maybe_emit_warning!(billable, limit_key, crossed)
          Result.warning(build_warning_message(limit_key, (limit_amount - current_usage - by), limit_amount), limit_key: limit_key, billable: billable, metadata: build_metadata(billable, limit_key, current_usage + by, limit_amount))
        else
          Result.within("#{limit_amount - current_usage - by} #{limit_key.to_s.humanize.downcase} remaining", metadata: build_metadata(billable, limit_key, current_usage + by, limit_amount))
        end
      end
    end

    def require_feature!(feature_key, billable:)
      plan = PlanResolver.effective_plan_for(billable)
      unless plan&.allows_feature?(feature_key)
        highlighted_plan = Registry.highlighted_plan
        current_plan_name = plan&.name || Registry.default_plan&.name || "Current"
        feature_human = feature_key.to_s.humanize
        message = if highlighted_plan
          "Your current plan (#{current_plan_name}) doesn't allow you to #{feature_human}. Please upgrade to #{highlighted_plan.name}."
        else
          "#{feature_human} is not available on your current plan (#{current_plan_name})."
        end
        raise FeatureDenied.new(message, feature_key: feature_key, billable: billable)
      end
      true
    end

    # Syntactic sugar: dynamic helpers
    def self.included(base)
      base.define_method(:method_missing) do |method_name, *args, &block|
        name = method_name.to_s
        if name.end_with?("_limit!") && name.start_with?("enforce_")
          limit_key = name.sub(/^enforce_/, '').sub(/_limit!$/, '').to_sym
          options = args.first.is_a?(Hash) ? args.first : {}
          billable = options[:billable] || (options[:on] && (options[:on].is_a?(Symbol) ? send(options[:on]) : instance_exec(&options[:on]))) || (options[:for] && (options[:for].is_a?(Symbol) ? send(options[:for]) : instance_exec(&options[:for])))
          by = options.key?(:by) ? options[:by] : 1
          allow_system_override = !!options[:allow_system_override]
          result = PricingPlans::ControllerGuards.require_plan_limit!(limit_key, billable: billable, by: by, allow_system_override: allow_system_override)
          return true unless result.blocked?
          return true if allow_system_override && result.metadata && result.metadata[:system_override]
          throw :abort if defined?(throw)
          return false
        elsif name.start_with?("enforce_") && name.end_with?("!")
          feature_key = name.sub(/^enforce_/, '').sub(/!$/, '').to_sym
          options = args.first.is_a?(Hash) ? args.first : {}
          billable = options[:billable] || (options[:on] && (options[:on].is_a?(Symbol) ? send(options[:on]) : instance_exec(&options[:on]))) || (options[:for] && (options[:for].is_a?(Symbol) ? send(options[:for]) : instance_exec(&options[:for])))
          PricingPlans::ControllerGuards.require_feature!(feature_key, billable: billable)
          return true
        end
        super(method_name, *args, &block)
      end if base.respond_to?(:define_method)

      base.define_method(:respond_to_missing?) do |method_name, include_private = false|
        str = method_name.to_s
        (str.start_with?("enforce_") && str.end_with?("!")) || super(method_name, include_private)
      end if base.respond_to?(:define_method)
    end

    private

    def handle_warning_only(_billable, limit_key, current_usage, limit_amount)
      Result.warning(build_over_limit_message(limit_key, current_usage, limit_amount, :warning))
    end

    def build_warning_message(limit_key, remaining, limit_amount)
      resource = limit_key.to_s.humanize.downcase
      "You have #{remaining} #{resource} remaining out of #{limit_amount}"
    end

    def build_over_limit_message(limit_key, current_usage, limit_amount, _severity)
      resource = limit_key.to_s.humanize.downcase
      highlighted_plan = Registry.highlighted_plan
      base = "You've reached your limit of #{limit_amount} #{resource} (currently using #{current_usage})"
      return base unless highlighted_plan
      "#{base}. Upgrade to #{highlighted_plan.name} for higher limits"
    end

    def build_grace_message(limit_key, current_usage, limit_amount, grace_ends_at)
      resource = limit_key.to_s.humanize.downcase
      highlighted_plan = Registry.highlighted_plan
      time_remaining = time_ago_in_words(grace_ends_at)
      base = "You've exceeded your limit of #{limit_amount} #{resource}. You have #{time_remaining} remaining in your grace period"
      return base unless highlighted_plan
      "#{base}. Upgrade to #{highlighted_plan.name} to avoid service interruption"
    end

    def time_ago_in_words(future_time)
      return "no time" if future_time <= Time.current
      distance = future_time - Time.current
      case distance
      when 0...60 then "#{distance.round} seconds"
      when 60...3600 then "#{(distance / 60).round} minutes"
      when 3600...86400 then "#{(distance / 3600).round} hours"
      else "#{(distance / 86400).round} days"
      end
    end

    def build_metadata(_billable, _limit_key, usage, limit_amount, grace_ends_at: nil)
      {
        limit_amount: limit_amount,
        current_usage: usage,
        percent_used: (limit_amount == :unlimited || limit_amount.to_i.zero?) ? 0.0 : [(usage.to_f / limit_amount) * 100, 100.0].min,
        grace_ends_at: grace_ends_at
      }
    end
  end
end
