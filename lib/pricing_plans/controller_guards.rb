# frozen_string_literal: true

module PricingPlans
  module ControllerGuards
    extend self

    # When included into a controller, provide dynamic helpers and callbacks
    def self.included(base)
      if base.respond_to?(:class_attribute)
        base.class_attribute :pricing_plans_plan_owner_method, instance_accessor: false, default: nil
        base.class_attribute :pricing_plans_plan_owner_proc, instance_accessor: false, default: nil
        # Optional per-controller default redirect target when a limit blocks
        # Accepts the same types as the global configuration: Symbol | String | Proc
        base.class_attribute :pricing_plans_redirect_on_blocked_limit, instance_accessor: false, default: nil
      end
      # Fallback storage on eigenclass for environments without class_attribute
      if !base.respond_to?(:pricing_plans_plan_owner_proc) && base.respond_to?(:singleton_class)
        base.singleton_class.send(:attr_accessor, :_pricing_plans_plan_owner_proc)
      end
      if !base.respond_to?(:pricing_plans_redirect_on_blocked_limit) && base.respond_to?(:singleton_class)
        base.singleton_class.send(:attr_accessor, :_pricing_plans_redirect_on_blocked_limit)
      end

      # Provide portable class-level API for redirect default regardless of class_attribute availability
      if base.respond_to?(:define_singleton_method)
        unless base.respond_to?(:pricing_plans_redirect_on_blocked_limit=)
          base.define_singleton_method(:pricing_plans_redirect_on_blocked_limit=) do |value|
            if respond_to?(:pricing_plans_redirect_on_blocked_limit)
              self.pricing_plans_redirect_on_blocked_limit = value
            elsif respond_to?(:_pricing_plans_redirect_on_blocked_limit=)
              self._pricing_plans_redirect_on_blocked_limit = value
            end
          end
        end
        unless base.respond_to?(:pricing_plans_redirect_on_blocked_limit)
          base.define_singleton_method(:pricing_plans_redirect_on_blocked_limit) do
            if respond_to?(:_pricing_plans_redirect_on_blocked_limit)
              self._pricing_plans_redirect_on_blocked_limit
            else
              nil
            end
          end
        end
      end

      base.define_singleton_method(:pricing_plans_plan_owner) do |method_name = nil, &block|
        if method_name
          self.pricing_plans_plan_owner_method = method_name.to_sym
          self.pricing_plans_plan_owner_proc = nil
          self._pricing_plans_plan_owner_proc = nil if respond_to?(:_pricing_plans_plan_owner_proc)
        elsif block_given?
          # Store the block and use instance_exec at call time
          self.pricing_plans_plan_owner_proc = block
          self._pricing_plans_plan_owner_proc = block if respond_to?(:_pricing_plans_plan_owner_proc)
          self.pricing_plans_plan_owner_method = nil
        else
          self.pricing_plans_plan_owner_method
        end
      end if base.respond_to?(:define_singleton_method)

      base.define_method(:pricing_plans_plan_owner) do
        # 1) Explicit per-controller configuration wins
        if self.class.respond_to?(:pricing_plans_plan_owner_proc) && self.class.pricing_plans_plan_owner_proc
          return instance_exec(&self.class.pricing_plans_plan_owner_proc)
        elsif self.class.respond_to?(:_pricing_plans_plan_owner_proc) && self.class._pricing_plans_plan_owner_proc
          return instance_exec(&self.class._pricing_plans_plan_owner_proc)
        elsif self.class.respond_to?(:pricing_plans_plan_owner_method) && self.class.pricing_plans_plan_owner_method
          return send(self.class.pricing_plans_plan_owner_method)
        end

        # 2) Global controller resolver if configured
        begin
          cfg = PricingPlans.configuration
          if cfg
            if cfg.controller_plan_owner_proc
              return instance_exec(&cfg.controller_plan_owner_proc)
            elsif cfg.controller_plan_owner_method
              meth = cfg.controller_plan_owner_method
              return send(meth) if respond_to?(meth)
            end
          end
        rescue StandardError
        end

        # 3) Infer from configured plan owner class (current_organization, etc.)
        owner_klass = PricingPlans::Registry.plan_owner_class rescue nil
        if owner_klass
          inferred = "current_#{owner_klass.name.underscore}"
          return send(inferred) if respond_to?(inferred)
        end

        # 4) Common conventions
        %i[current_organization current_account current_user current_team current_company current_workspace current_tenant].each do |meth|
          return send(meth) if respond_to?(meth)
        end

        raise PricingPlans::ConfigurationError, "Unable to infer plan owner for controller. Set `self.pricing_plans_plan_owner_method = :current_organization` or provide a block via `pricing_plans_plan_owner { ... }`."
      end if base.respond_to?(:define_method)

      # Dynamic enforce_*! and with_*! helpers for before_action ergonomics
      base.define_method(:method_missing) do |method_name, *args, &block|
        if method_name.to_s =~ /^with_(.+)_limit!$/
          limit_key = Regexp.last_match(1).to_sym
          options = args.first.is_a?(Hash) ? args.first : {}
          owner = if options[:plan_owner]
            options[:plan_owner]
          elsif options[:on]
            resolver = options[:on]
            resolver.is_a?(Symbol) ? send(resolver) : instance_exec(&resolver)
          elsif options[:for]
            resolver = options[:for]
            resolver.is_a?(Symbol) ? send(resolver) : instance_exec(&resolver)
          else
            respond_to?(:pricing_plans_plan_owner) ? pricing_plans_plan_owner : nil
          end
          by = options.key?(:by) ? options[:by] : 1
          allow_system_override = !!options[:allow_system_override]
          redirect_path = options[:redirect_to]
          return with_plan_limit!(limit_key, plan_owner: owner, by: by, allow_system_override: allow_system_override, redirect_to: redirect_path, &block)
        elsif method_name.to_s =~ /^enforce_(.+)_limit!$/
          limit_key = Regexp.last_match(1).to_sym
          options = args.first.is_a?(Hash) ? args.first : {}
          owner = if options[:plan_owner]
            options[:plan_owner]
          elsif options[:on]
            resolver = options[:on]
            resolver.is_a?(Symbol) ? send(resolver) : instance_exec(&resolver)
          elsif options[:for]
            resolver = options[:for]
            resolver.is_a?(Symbol) ? send(resolver) : instance_exec(&resolver)
          else
            respond_to?(:pricing_plans_plan_owner) ? pricing_plans_plan_owner : nil
          end
          by = options.key?(:by) ? options[:by] : 1
          allow_system_override = !!options[:allow_system_override]
          redirect_path = options[:redirect_to]
          return enforce_plan_limit!(limit_key, plan_owner: owner, by: by, allow_system_override: allow_system_override, redirect_to: redirect_path)
        elsif method_name.to_s =~ /^enforce_(.+)!$/
          feature_key = Regexp.last_match(1).to_sym
          options = args.first.is_a?(Hash) ? args.first : {}
          # Support: enforce_feature!(for: :current_organization) and enforce_feature!(plan_owner: obj)
          owner = if options[:plan_owner]
            options[:plan_owner]
          elsif options[:on]
            resolver = options[:on]
            resolver.is_a?(Symbol) ? send(resolver) : instance_exec(&resolver)
          elsif options[:for]
            resolver = options[:for]
            resolver.is_a?(Symbol) ? send(resolver) : instance_exec(&resolver)
          else
            respond_to?(:pricing_plans_plan_owner) ? pricing_plans_plan_owner : nil
          end
          require_feature!(feature_key, plan_owner: owner)
          return true
        end
        super(method_name, *args, &block)
      end if base.respond_to?(:define_method)

      base.define_method(:respond_to_missing?) do |method_name, include_private = false|
        ((method_name.to_s.start_with?("enforce_") || method_name.to_s.start_with?("with_")) && method_name.to_s.end_with?("!")) || super(method_name, include_private)
      end if base.respond_to?(:define_method)
    end

    # Checks if a given plan_owner object is within the plan limit for a specific key.
    #
    # Usage:
    #   result = require_plan_limit!(:projects, plan_owner: current_organization)
    #   if result.blocked?
    #     # Handle blocked case (e.g., show upgrade prompt)
    #     redirect_to upgrade_path, alert: result.message
    #   elsif result.warning?
    #     flash[:warning] = result.message
    #   end
    #
    # Options:
    #   - limit_key:        The symbol for the limit (e.g., :projects)
    #   - plan_owner:         The plan_owner object (e.g., current_organization)
    #   - by:               The number of units to check for (default: 1)
    #   - allow_system_override: If true, returns a blocked result but does not enforce the block (default: false)
    #
    # Returns a PricingPlans::Result with state:
    #   - :within   (allowed)
    #   - :warning  (allowed, but near limit)
    #   - :grace    (allowed, but in grace period)
    #   - :blocked  (not allowed)
    def require_plan_limit!(limit_key, plan_owner: nil, by: 1, allow_system_override: false)
      plan_owner ||= (respond_to?(:pricing_plans_plan_owner) ? pricing_plans_plan_owner : nil)
      plan = PlanResolver.effective_plan_for(plan_owner)
      limit_config = plan&.limit_for(limit_key)

      # BREAKING CHANGE: If no limit is configured, block the action (secure by default)
      # Previously this returned :within (allowed), now returns :blocked
      unless limit_config
        return Result.blocked("Limit #{limit_key.to_s.humanize.downcase} not configured on this plan")
      end

      # Check if unlimited
      if limit_config[:to] == :unlimited
        return Result.within("Unlimited #{limit_key}")
      end

      # Check current usage and remaining capacity
      current_usage = LimitChecker.current_usage_for(plan_owner, limit_key, limit_config)
      limit_amount = limit_config[:to]
      remaining = limit_amount - current_usage

      # Check if this action would exceed the limit
      would_exceed = remaining < by

      if would_exceed
        # Allow trusted flows to bypass hard block while signaling downstream
        if allow_system_override
          metadata = build_metadata(plan_owner, limit_key, current_usage, limit_amount)
          return Result.new(state: :blocked, message: build_over_limit_message(limit_key, current_usage, limit_amount, :blocked), limit_key: limit_key, plan_owner: plan_owner, metadata: metadata.merge(system_override: true))
        end
        # Handle exceeded limit based on after_limit policy
        case limit_config[:after_limit]
        when :just_warn
          handle_warning_only(plan_owner, limit_key, current_usage, limit_amount)
        when :block_usage
          handle_immediate_block(plan_owner, limit_key, current_usage, limit_amount)
        when :grace_then_block
          handle_grace_then_block(plan_owner, limit_key, current_usage, limit_amount, limit_config)
        else
          Result.blocked("Unknown after_limit policy: #{limit_config[:after_limit]}")
        end
      else
        # Within limit - check for warnings
        handle_within_limit(plan_owner, limit_key, current_usage, limit_amount, by)
      end
    end

    # Rails-y controller ergonomics: enforce limits and set flash/redirect when blocked.
    # Defaults:
    # - On blocked: redirect_to pricing_path (if available) with alert; else render 403 JSON.
    # - On grace/warning: set flash[:warning] with the human message.
    def enforce_plan_limit!(limit_key, plan_owner: nil, by: 1, allow_system_override: false, redirect_to: nil)
      plan_owner ||= (respond_to?(:pricing_plans_plan_owner) ? pricing_plans_plan_owner : nil)
      result = require_plan_limit!(limit_key, plan_owner: plan_owner, by: by, allow_system_override: allow_system_override)

      if result.blocked?
        # If caller opted into system override, let them handle downstream
        if allow_system_override && result.metadata && result.metadata[:system_override]
          return true
        end

        # Resolve the best redirect target once, and surface it to any handler via metadata
        resolved_target = resolve_redirect_target_for_blocked_limit(result, redirect_to)

        if respond_to?(:handle_pricing_plans_limit_blocked)
          # Enrich result with redirect target for the centralized handler
          enriched_result = PricingPlans::Result.blocked(
            result.message,
            limit_key: result.limit_key,
            plan_owner: result.plan_owner,
            metadata: (result.metadata || {}).merge(redirect_to: resolved_target)
          )
          handle_pricing_plans_limit_blocked(enriched_result)
        else
          # Local fallback when centralized handler isn't available
          if resolved_target && respond_to?(:redirect_to)
            redirect_to(resolved_target, alert: result.message, status: :see_other)
          elsif respond_to?(:render)
            respond_to?(:request) && request&.format&.json? ? render(json: { error: result.message }, status: :forbidden) : render(plain: result.message, status: :forbidden)
          end
        end
        return false
      elsif result.warning? || result.grace?
        if respond_to?(:flash) && flash.respond_to?(:[]=)
          flash[:warning] ||= result.message
        end
      end

      true
    end

    # Controller-focused sugar: run a block within the plan limit context.
    # - If blocked: performs the same redirect/render semantics as enforce_plan_limit! and returns false.
    # - If warning/grace: sets flash[:warning] and yields the result.
    # - If within: simply yields the result.
    # Returns the PricingPlans::Result in all cases where execution continues.
    #
    # Usage:
    #   with_plan_limit!(:licenses, plan_owner: current_organization, by: 1) do |result|
    #     # proceed with side-effects, can inspect result.warning?/grace?
    #   end
    def with_plan_limit!(limit_key, plan_owner: nil, by: 1, allow_system_override: false, redirect_to: nil, &block)
      plan_owner ||= (respond_to?(:pricing_plans_plan_owner) ? pricing_plans_plan_owner : nil)
      result = require_plan_limit!(limit_key, plan_owner: plan_owner, by: by, allow_system_override: allow_system_override)

      if result.blocked?
        # If caller opted into system override, let them proceed (exposes blocked state to the block)
        if allow_system_override && result.metadata && result.metadata[:system_override]
          yield(result) if block_given?
          return result
        end

        # Resolve redirect target and delegate to centralized handler if available
        resolved_target = resolve_redirect_target_for_blocked_limit(result, redirect_to)
        if respond_to?(:handle_pricing_plans_limit_blocked)
          enriched_result = PricingPlans::Result.blocked(
            result.message,
            limit_key: result.limit_key,
            plan_owner: result.plan_owner,
            metadata: (result.metadata || {}).merge(redirect_to: resolved_target)
          )
          handle_pricing_plans_limit_blocked(enriched_result)
        else
          if resolved_target && respond_to?(:redirect_to)
            redirect_to(resolved_target, alert: result.message, status: :see_other)
          elsif respond_to?(:render)
            respond_to?(:request) && request&.format&.json? ? render(json: { error: result.message }, status: :forbidden) : render(plain: result.message, status: :forbidden)
          end
        end
        return false
      else
        if (result.warning? || result.grace?) && respond_to?(:flash) && flash.respond_to?(:[]=)
          flash[:warning] ||= result.message
        end
        yield(result) if block_given?
        return result
      end
    end

    private

    # Decide which redirect target to use when a limit is blocked.
    # Resolution order:
    # 1) explicit option passed to the call
    # 2) per-controller default (Symbol | String | Proc)
    # 3) global configuration default (Symbol | String | Proc)
    # 4) pricing_path helper if available
    # Returns a String path or nil
    def resolve_redirect_target_for_blocked_limit(result, explicit)
      return explicit if explicit && !explicit.is_a?(Proc)

      path = nil
      # Per-controller default
      ctrl = if self.class.respond_to?(:pricing_plans_redirect_on_blocked_limit)
        self.class.pricing_plans_redirect_on_blocked_limit
      elsif self.class.respond_to?(:_pricing_plans_redirect_on_blocked_limit)
        self.class._pricing_plans_redirect_on_blocked_limit
      else
        nil
      end
      candidate = explicit || ctrl
      case candidate
      when Symbol
        path = send(candidate) if respond_to?(candidate)
      when String
        path = candidate
      when Proc
        begin
          path = instance_exec(result, &candidate)
        rescue StandardError
          path = nil
        end
      end

      if path.nil?
        global = PricingPlans.configuration.redirect_on_blocked_limit rescue nil
        case global
        when Symbol
          path = send(global) if respond_to?(global)
        when String
          path = global
        when Proc
          begin
            path = instance_exec(result, &global)
          rescue StandardError
            path = nil
          end
        end
      end

      path ||= (respond_to?(:pricing_path) ? pricing_path : nil)
      path
    end

    public

    # Preferred alias for feature gating (plain-English name)
    def gate_feature!(feature_key, plan_owner: nil)
      plan_owner ||= (respond_to?(:pricing_plans_plan_owner) ? pricing_plans_plan_owner : nil)
      require_feature!(feature_key, plan_owner: plan_owner)
    end

    def require_feature!(feature_key, plan_owner:)
      plan = PlanResolver.effective_plan_for(plan_owner)

      unless plan&.allows_feature?(feature_key)
        highlighted_plan = Registry.highlighted_plan
        current_plan_name = plan&.name || Registry.default_plan&.name || "Current"
        feature_human = feature_key.to_s.humanize
        upgrade_message = if PricingPlans.configuration&.message_builder
          begin
            builder = PricingPlans.configuration.message_builder
            builder.call(context: :feature_denied, feature_key: feature_key, plan_owner: plan_owner, plan_name: current_plan_name, highlighted_plan: highlighted_plan&.name)
          rescue StandardError
            nil
          end
        end
        upgrade_message ||= if highlighted_plan
          "Your current plan (#{current_plan_name}) doesn't allow you to #{feature_human}. Please upgrade to #{highlighted_plan.name} or higher to access #{feature_human}."
        else
          "#{feature_human} is not available on your current plan (#{current_plan_name})."
        end

        raise FeatureDenied.new(upgrade_message, feature_key: feature_key, plan_owner: plan_owner)
      end

      true
    end

    private

    def handle_within_limit(plan_owner, limit_key, current_usage, limit_amount, by)
      # Check for warning thresholds
      percent_after_action = ((current_usage + by).to_f / limit_amount) * 100
      warning_thresholds = LimitChecker.warning_thresholds(plan_owner, limit_key)

      crossed_threshold = warning_thresholds.find do |threshold|
        threshold_percent = threshold * 100
        current_percent = (current_usage.to_f / limit_amount) * 100

        # Threshold will be crossed by this action
        current_percent < threshold_percent && percent_after_action >= threshold_percent
      end

      if crossed_threshold
        # Emit warning event
        GraceManager.maybe_emit_warning!(plan_owner, limit_key, crossed_threshold)

        remaining = limit_amount - current_usage - by
        warning_message = build_warning_message(limit_key, remaining, limit_amount)
        metadata = build_metadata(plan_owner, limit_key, current_usage + by, limit_amount)
        Result.warning(warning_message, limit_key: limit_key, plan_owner: plan_owner, metadata: metadata)
      else
        remaining = limit_amount - current_usage - by
        metadata = build_metadata(plan_owner, limit_key, current_usage + by, limit_amount)
        Result.within("#{remaining} #{limit_key.to_s.humanize.downcase} remaining", metadata: metadata)
      end
    end

    def handle_warning_only(plan_owner, limit_key, current_usage, limit_amount)
      warning_message = build_over_limit_message(limit_key, current_usage, limit_amount, :warning)
      metadata = build_metadata(plan_owner, limit_key, current_usage, limit_amount)
      Result.warning(warning_message, limit_key: limit_key, plan_owner: plan_owner, metadata: metadata)
    end

    def handle_immediate_block(plan_owner, limit_key, current_usage, limit_amount)
      blocked_message = build_over_limit_message(limit_key, current_usage, limit_amount, :blocked)

      # Mark as blocked immediately
      GraceManager.mark_blocked!(plan_owner, limit_key)

      metadata = build_metadata(plan_owner, limit_key, current_usage, limit_amount)
      Result.blocked(blocked_message, limit_key: limit_key, plan_owner: plan_owner, metadata: metadata)
    end

    def handle_grace_then_block(plan_owner, limit_key, current_usage, limit_amount, limit_config)
      # Check if already in grace or blocked
      if GraceManager.should_block?(plan_owner, limit_key)
        # Mark as blocked if not already blocked
        GraceManager.mark_blocked!(plan_owner, limit_key)
        blocked_message = build_over_limit_message(limit_key, current_usage, limit_amount, :blocked)
        metadata = build_metadata(plan_owner, limit_key, current_usage, limit_amount)
        Result.blocked(blocked_message, limit_key: limit_key, plan_owner: plan_owner, metadata: metadata)
      elsif GraceManager.grace_active?(plan_owner, limit_key)
        # Already in grace period
        grace_ends_at = GraceManager.grace_ends_at(plan_owner, limit_key)
        grace_message = build_grace_message(limit_key, current_usage, limit_amount, grace_ends_at)
        metadata = build_metadata(plan_owner, limit_key, current_usage, limit_amount, grace_ends_at: grace_ends_at)
        Result.grace(grace_message, limit_key: limit_key, plan_owner: plan_owner, metadata: metadata)
      else
        # Start grace period
        GraceManager.mark_exceeded!(plan_owner, limit_key, grace_period: limit_config[:grace])
        grace_ends_at = GraceManager.grace_ends_at(plan_owner, limit_key)
        grace_message = build_grace_message(limit_key, current_usage, limit_amount, grace_ends_at)
        metadata = build_metadata(plan_owner, limit_key, current_usage, limit_amount, grace_ends_at: grace_ends_at)
        Result.grace(grace_message, limit_key: limit_key, plan_owner: plan_owner, metadata: metadata)
      end
    end

    def build_warning_message(limit_key, remaining, limit_amount)
      resource_name = limit_key.to_s.humanize.downcase
      "You have #{remaining} #{resource_name} remaining out of #{limit_amount}"
    end

    def build_over_limit_message(limit_key, current_usage, limit_amount, severity)
      resource_name = limit_key.to_s.humanize.downcase
      highlighted_plan = Registry.highlighted_plan

      # Allow global message builder override
      if PricingPlans.configuration&.message_builder
        begin
          built = PricingPlans.configuration.message_builder.call(
            context: :over_limit,
            limit_key: limit_key,
            current_usage: current_usage,
            limit_amount: limit_amount,
            severity: severity,
            highlighted_plan: highlighted_plan&.name
          )
          return built if built
        rescue StandardError
          # fall through to default
        end
      end

      base_message = "You've reached your limit of #{limit_amount} #{resource_name} (currently using #{current_usage})"

      return base_message unless highlighted_plan
      upgrade_cta = "Upgrade to #{highlighted_plan.name} for higher limits"
      "#{base_message}. #{upgrade_cta}"
    end

    def build_grace_message(limit_key, current_usage, limit_amount, grace_ends_at)
      resource_name = limit_key.to_s.humanize.downcase
      highlighted_plan = Registry.highlighted_plan

      if PricingPlans.configuration&.message_builder
        begin
          built = PricingPlans.configuration.message_builder.call(
            context: :grace,
            limit_key: limit_key,
            current_usage: current_usage,
            limit_amount: limit_amount,
            grace_ends_at: grace_ends_at,
            highlighted_plan: highlighted_plan&.name
          )
          return built if built
        rescue StandardError
        end
      end

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

    def build_metadata(plan_owner, limit_key, usage, limit_amount, grace_ends_at: nil)
      {
        limit_amount: limit_amount,
        current_usage: usage,
        percent_used: (limit_amount == :unlimited || limit_amount.to_i.zero?) ? 0.0 : [(usage.to_f / limit_amount) * 100, 100.0].min,
        grace_ends_at: grace_ends_at
      }
    end
  end
end
