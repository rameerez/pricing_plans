# frozen_string_literal: true

module PricingPlans
  module ControllerGuards
    extend self

    # When included into a controller, provide dynamic helpers and callbacks
    def self.included(base)
      if base.respond_to?(:class_attribute)
        base.class_attribute :pricing_plans_billable_method, instance_accessor: false, default: nil
        base.class_attribute :pricing_plans_billable_proc, instance_accessor: false, default: nil
      end
      # Fallback storage on eigenclass for environments without class_attribute
      if !base.respond_to?(:pricing_plans_billable_proc) && base.respond_to?(:singleton_class)
        base.singleton_class.send(:attr_accessor, :_pricing_plans_billable_proc)
      end

      base.define_singleton_method(:pricing_plans_billable) do |method_name = nil, &block|
        if method_name
          self.pricing_plans_billable_method = method_name.to_sym
          self.pricing_plans_billable_proc = nil
          self._pricing_plans_billable_proc = nil if respond_to?(:_pricing_plans_billable_proc)
        elsif block_given?
          # Store the block and use instance_exec at call time
          self.pricing_plans_billable_proc = block
          self._pricing_plans_billable_proc = block if respond_to?(:_pricing_plans_billable_proc)
          self.pricing_plans_billable_method = nil
        else
          self.pricing_plans_billable_method
        end
      end if base.respond_to?(:define_singleton_method)

      base.define_method(:pricing_plans_billable) do
        # 1) Explicit per-controller configuration wins
        if self.class.respond_to?(:pricing_plans_billable_proc) && self.class.pricing_plans_billable_proc
          return instance_exec(&self.class.pricing_plans_billable_proc)
        elsif self.class.respond_to?(:_pricing_plans_billable_proc) && self.class._pricing_plans_billable_proc
          return instance_exec(&self.class._pricing_plans_billable_proc)
        elsif self.class.respond_to?(:pricing_plans_billable_method) && self.class.pricing_plans_billable_method
          return send(self.class.pricing_plans_billable_method)
        end

        # 2) Infer from configured billable class (current_organization, etc.)
        billable_klass = PricingPlans::Registry.billable_class rescue nil
        if billable_klass
          inferred = "current_#{billable_klass.name.underscore}"
          return send(inferred) if respond_to?(inferred)
        end

        # 3) Common conventions
        %i[current_organization current_account current_user current_team current_company current_workspace current_tenant].each do |meth|
          return send(meth) if respond_to?(meth)
        end

        raise PricingPlans::ConfigurationError, "Unable to infer billable for controller. Set `self.pricing_plans_billable_method = :current_organization` or provide a block via `pricing_plans_billable { ... }`."
      end if base.respond_to?(:define_method)

      # Dynamic enforce_*! feature guards for before_action ergonomics
      base.define_method(:method_missing) do |method_name, *args, &block|
        if method_name.to_s =~ /^enforce_(.+)_limit!$/
          limit_key = Regexp.last_match(1).to_sym
          options = args.first.is_a?(Hash) ? args.first : {}
          billable = if options[:billable]
            options[:billable]
          elsif options[:on]
            resolver = options[:on]
            resolver.is_a?(Symbol) ? send(resolver) : instance_exec(&resolver)
          elsif options[:for]
            resolver = options[:for]
            resolver.is_a?(Symbol) ? send(resolver) : instance_exec(&resolver)
          else
            respond_to?(:pricing_plans_billable) ? pricing_plans_billable : nil
          end
          by = options.key?(:by) ? options[:by] : 1
          allow_system_override = !!options[:allow_system_override]
          redirect_path = options[:redirect_to]
          enforce_plan_limit!(limit_key, billable: billable, by: by, allow_system_override: allow_system_override, redirect_to: redirect_path)
          return true
        elsif method_name.to_s =~ /^enforce_(.+)!$/
          feature_key = Regexp.last_match(1).to_sym
          options = args.first.is_a?(Hash) ? args.first : {}
          # Support: enforce_feature!(for: :current_organization) and enforce_feature!(billable: obj)
          billable = if options[:billable]
            options[:billable]
          elsif options[:on]
            resolver = options[:on]
            resolver.is_a?(Symbol) ? send(resolver) : instance_exec(&resolver)
          elsif options[:for]
            resolver = options[:for]
            resolver.is_a?(Symbol) ? send(resolver) : instance_exec(&resolver)
          else
            respond_to?(:pricing_plans_billable) ? pricing_plans_billable : nil
          end
          require_feature!(feature_key, billable: billable)
          return true
        end
        super(method_name, *args, &block)
      end if base.respond_to?(:define_method)

      base.define_method(:respond_to_missing?) do |method_name, include_private = false|
        (method_name.to_s.start_with?("enforce_") && method_name.to_s.end_with?("!")) || super(method_name, include_private)
      end if base.respond_to?(:define_method)
    end

    def require_plan_limit!(limit_key, billable:, by: 1, allow_system_override: false)
      plan = PlanResolver.effective_plan_for(billable)
      limit_config = plan&.limit_for(limit_key)

      # If no limit is configured, allow the action
      unless limit_config
        return Result.within("No limit configured for #{limit_key}")
      end

      # Check if unlimited
      if limit_config[:to] == :unlimited
        return Result.within("Unlimited #{limit_key}")
      end

      # Check current usage and remaining capacity
      current_usage = LimitChecker.current_usage_for(billable, limit_key, limit_config)
      limit_amount = limit_config[:to]
      remaining = limit_amount - current_usage

      # Check if this action would exceed the limit
      would_exceed = remaining < by

      if would_exceed
        # Allow trusted flows to bypass hard block while signaling downstream
        if allow_system_override
          metadata = build_metadata(billable, limit_key, current_usage, limit_amount)
          return Result.new(state: :blocked, message: build_over_limit_message(limit_key, current_usage, limit_amount, :blocked), limit_key: limit_key, billable: billable, metadata: metadata.merge(system_override: true))
        end
        # Handle exceeded limit based on after_limit policy
        case limit_config[:after_limit]
        when :just_warn
          handle_warning_only(billable, limit_key, current_usage, limit_amount)
        when :block_usage
          handle_immediate_block(billable, limit_key, current_usage, limit_amount)
        when :grace_then_block
          handle_grace_then_block(billable, limit_key, current_usage, limit_amount, limit_config)
        else
          Result.blocked("Unknown after_limit policy: #{limit_config[:after_limit]}")
        end
      else
        # Within limit - check for warnings
        handle_within_limit(billable, limit_key, current_usage, limit_amount, by)
      end
    end

    # Rails-y controller ergonomics: enforce, set flash/redirect, and abort the callback chain when blocked.
    # Defaults:
    # - On blocked: redirect_to pricing_path (if available) with alert; else render 403 JSON.
    # - On grace/warning: set flash[:warning] with the human message.
    def enforce_plan_limit!(limit_key, billable:, by: 1, allow_system_override: false, redirect_to: nil)
      result = require_plan_limit!(limit_key, billable: billable, by: by, allow_system_override: allow_system_override)

      if result.blocked?
        # If caller opted into system override, let them handle downstream
        if allow_system_override && result.metadata && result.metadata[:system_override]
          return true
        end

        path = redirect_to
        path ||= (respond_to?(:pricing_path) ? pricing_path : nil)

        if path && respond_to?(:redirect_to)
          redirect_to(path, alert: result.message, status: :see_other)
        elsif respond_to?(:render)
          respond_to?(:request) && request&.format&.json? ? render(json: { error: result.message }, status: :forbidden) : render(plain: result.message, status: :forbidden)
        end
        # Stop the filter chain (for before_action ergonomics)
        throw :abort
        return false
      elsif result.warning? || result.grace?
        if respond_to?(:flash) && flash.respond_to?(:[]=)
          flash[:warning] ||= result.message
        end
      end

      true
    end

    def require_feature!(feature_key, billable:)
      plan = PlanResolver.effective_plan_for(billable)

      unless plan&.allows_feature?(feature_key)
        highlighted_plan = Registry.highlighted_plan
        current_plan_name = plan&.name || Registry.default_plan&.name || "Current"
        feature_human = feature_key.to_s.humanize
        upgrade_message = if highlighted_plan
          "Your current plan (#{current_plan_name}) doesn't allow you to #{feature_human}. Please upgrade to #{highlighted_plan.name} or higher to access #{feature_human}."
        else
          "#{feature_human} is not available on your current plan (#{current_plan_name})."
        end

        raise FeatureDenied.new(upgrade_message, feature_key: feature_key, billable: billable)
      end

      true
    end

    private

    def handle_within_limit(billable, limit_key, current_usage, limit_amount, by)
      # Check for warning thresholds
      percent_after_action = ((current_usage + by).to_f / limit_amount) * 100
      warning_thresholds = LimitChecker.warning_thresholds(billable, limit_key)

      crossed_threshold = warning_thresholds.find do |threshold|
        threshold_percent = threshold * 100
        current_percent = (current_usage.to_f / limit_amount) * 100

        # Threshold will be crossed by this action
        current_percent < threshold_percent && percent_after_action >= threshold_percent
      end

      if crossed_threshold
        # Emit warning event
        GraceManager.maybe_emit_warning!(billable, limit_key, crossed_threshold)

        remaining = limit_amount - current_usage - by
        warning_message = build_warning_message(limit_key, remaining, limit_amount)
        metadata = build_metadata(billable, limit_key, current_usage + by, limit_amount)
        Result.warning(warning_message, limit_key: limit_key, billable: billable, metadata: metadata)
      else
        remaining = limit_amount - current_usage - by
        metadata = build_metadata(billable, limit_key, current_usage + by, limit_amount)
        Result.within("#{remaining} #{limit_key.to_s.humanize.downcase} remaining", metadata: metadata)
      end
    end

    def handle_warning_only(billable, limit_key, current_usage, limit_amount)
      warning_message = build_over_limit_message(limit_key, current_usage, limit_amount, :warning)
      metadata = build_metadata(billable, limit_key, current_usage, limit_amount)
      Result.warning(warning_message, limit_key: limit_key, billable: billable, metadata: metadata)
    end

    def handle_immediate_block(billable, limit_key, current_usage, limit_amount)
      blocked_message = build_over_limit_message(limit_key, current_usage, limit_amount, :blocked)

      # Mark as blocked immediately
      GraceManager.mark_blocked!(billable, limit_key)

      metadata = build_metadata(billable, limit_key, current_usage, limit_amount)
      Result.blocked(blocked_message, limit_key: limit_key, billable: billable, metadata: metadata)
    end

    def handle_grace_then_block(billable, limit_key, current_usage, limit_amount, limit_config)
      # Check if already in grace or blocked
      if GraceManager.should_block?(billable, limit_key)
        # Mark as blocked if not already blocked
        GraceManager.mark_blocked!(billable, limit_key)
        blocked_message = build_over_limit_message(limit_key, current_usage, limit_amount, :blocked)
        metadata = build_metadata(billable, limit_key, current_usage, limit_amount)
        Result.blocked(blocked_message, limit_key: limit_key, billable: billable, metadata: metadata)
      elsif GraceManager.grace_active?(billable, limit_key)
        # Already in grace period
        grace_ends_at = GraceManager.grace_ends_at(billable, limit_key)
        grace_message = build_grace_message(limit_key, current_usage, limit_amount, grace_ends_at)
        metadata = build_metadata(billable, limit_key, current_usage, limit_amount, grace_ends_at: grace_ends_at)
        Result.grace(grace_message, limit_key: limit_key, billable: billable, metadata: metadata)
      else
        # Start grace period
        GraceManager.mark_exceeded!(billable, limit_key, grace_period: limit_config[:grace])
        grace_ends_at = GraceManager.grace_ends_at(billable, limit_key)
        grace_message = build_grace_message(limit_key, current_usage, limit_amount, grace_ends_at)
        metadata = build_metadata(billable, limit_key, current_usage, limit_amount, grace_ends_at: grace_ends_at)
        Result.grace(grace_message, limit_key: limit_key, billable: billable, metadata: metadata)
      end
    end

    def build_warning_message(limit_key, remaining, limit_amount)
      resource_name = limit_key.to_s.humanize.downcase
      "You have #{remaining} #{resource_name} remaining out of #{limit_amount}"
    end

    def build_over_limit_message(limit_key, current_usage, limit_amount, severity)
      resource_name = limit_key.to_s.humanize.downcase
      highlighted_plan = Registry.highlighted_plan

      base_message = "You've reached your limit of #{limit_amount} #{resource_name} (currently using #{current_usage})"

      return base_message unless highlighted_plan
      upgrade_cta = "Upgrade to #{highlighted_plan.name} for higher limits"
      "#{base_message}. #{upgrade_cta}"
    end

    def build_grace_message(limit_key, current_usage, limit_amount, grace_ends_at)
      resource_name = limit_key.to_s.humanize.downcase
      highlighted_plan = Registry.highlighted_plan

      time_remaining = time_ago_in_words(grace_ends_at)
      base_message = "You've exceeded your limit of #{limit_amount} #{resource_name}. " \
                    "You have #{time_remaining} remaining in your grace period"

      return base_message unless highlighted_plan
      upgrade_cta = "Upgrade to #{highlighted_plan.name} to avoid service interruption"
      "#{base_message}. #{upgrade_cta}"
    end

    def time_ago_in_words(future_time)
      return "no time" if future_time <= Time.current

      distance = future_time - Time.current

      case distance
      when 0...60
        "#{distance.round} seconds"
      when 60...3600
        "#{(distance / 60).round} minutes"
      when 3600...86400
        "#{(distance / 3600).round} hours"
      else
        "#{(distance / 86400).round} days"
      end
    end

    def build_metadata(billable, limit_key, usage, limit_amount, grace_ends_at: nil)
      {
        limit_amount: limit_amount,
        current_usage: usage,
        percent_used: (limit_amount == :unlimited || limit_amount.to_i.zero?) ? 0.0 : [(usage.to_f / limit_amount) * 100, 100.0].min,
        grace_ends_at: grace_ends_at
      }
    end
  end
end
