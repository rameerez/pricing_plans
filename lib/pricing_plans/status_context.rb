# frozen_string_literal: true

module PricingPlans
  # Request-scoped context that caches computed values within a single status() call.
  # This eliminates the N+1 query problem where helper methods like severity_for(),
  # message_for(), overage_for() etc. all re-call limit_status() internally.
  #
  # Thread-safe by design: each call to status() gets its own context instance.
  class StatusContext
    attr_reader :plan_owner

    def initialize(plan_owner)
      @plan_owner = plan_owner
      @plan_cache = nil
      @limit_config_cache = {}
      @limit_status_cache = {}
      @usage_cache = {}
      @grace_active_cache = {}
      @grace_ends_at_cache = {}
      @should_block_cache = {}
      @percent_used_cache = {}
      @warning_thresholds_cache = {}
      @severity_cache = {}
    end

    # ========== PUBLIC API ==========

    # Cached plan resolution - called once per context
    def effective_plan
      @plan_cache ||= PlanResolver.effective_plan_for(@plan_owner)
    end

    # Cached limit config lookup
    def limit_config_for(limit_key)
      key = limit_key.to_sym
      return @limit_config_cache[key] if @limit_config_cache.key?(key)
      @limit_config_cache[key] = effective_plan&.limit_for(limit_key)
    end

    # Cached current usage lookup
    def current_usage_for(limit_key)
      key = limit_key.to_sym
      return @usage_cache[key] if @usage_cache.key?(key)

      limit_config = limit_config_for(limit_key)
      @usage_cache[key] = limit_config ? LimitChecker.current_usage_for(@plan_owner, limit_key, limit_config) : 0
    end

    # Cached percent used
    def percent_used_for(limit_key)
      key = limit_key.to_sym
      return @percent_used_cache[key] if @percent_used_cache.key?(key)

      limit_config = limit_config_for(limit_key)
      return @percent_used_cache[key] = 0.0 unless limit_config

      limit_amount = limit_config[:to]
      return @percent_used_cache[key] = 0.0 if limit_amount == :unlimited || limit_amount.to_i.zero?

      usage = current_usage_for(limit_key)
      @percent_used_cache[key] = [(usage.to_f / limit_amount) * 100, 100.0].min
    end

    # Cached grace active check - implemented directly to avoid GraceManager's plan resolution
    def grace_active?(limit_key)
      key = limit_key.to_sym
      return @grace_active_cache[key] if @grace_active_cache.key?(key)

      state = fresh_enforcement_state(limit_key)
      return @grace_active_cache[key] = false unless state&.exceeded?
      @grace_active_cache[key] = !state.grace_expired?
    end

    # Cached grace ends at - uses fresh_enforcement_state to avoid stale data
    def grace_ends_at(limit_key)
      key = limit_key.to_sym
      return @grace_ends_at_cache[key] if @grace_ends_at_cache.key?(key)

      state = fresh_enforcement_state(limit_key)
      @grace_ends_at_cache[key] = state&.grace_ends_at
    end

    # Cached should block check - implemented directly to avoid GraceManager's plan resolution
    def should_block?(limit_key)
      key = limit_key.to_sym
      return @should_block_cache[key] if @should_block_cache.key?(key)

      limit_config = limit_config_for(limit_key)
      return @should_block_cache[key] = false unless limit_config

      after_limit = limit_config[:after_limit]
      return @should_block_cache[key] = false if after_limit == :just_warn

      limit_amount = limit_config[:to]
      return @should_block_cache[key] = false if limit_amount == :unlimited

      current_usage = current_usage_for(limit_key)
      exceeded = current_usage >= limit_amount.to_i
      exceeded = false if limit_amount.to_i.zero? && current_usage.to_i.zero?

      return @should_block_cache[key] = exceeded if after_limit == :block_usage

      # For :grace_then_block, check if grace period expired
      return @should_block_cache[key] = false unless exceeded

      state = fresh_enforcement_state(limit_key)
      return @should_block_cache[key] = false unless state&.exceeded?
      @should_block_cache[key] = state.grace_expired?
    end

    # Cached warning thresholds
    def warning_thresholds(limit_key)
      key = limit_key.to_sym
      return @warning_thresholds_cache[key] if @warning_thresholds_cache.key?(key)

      limit_config = limit_config_for(limit_key)
      @warning_thresholds_cache[key] = limit_config ? (limit_config[:warn_at] || []) : []
    end

    # Cached period window calculation - delegates to PeriodCalculator with pre-resolved period_type
    # to avoid redundant effective_plan_for calls
    def period_window_for(limit_key)
      key = limit_key.to_sym
      @period_window_cache ||= {}
      return @period_window_cache[key] if @period_window_cache.key?(key)

      limit_config = limit_config_for(limit_key)
      return @period_window_cache[key] = [nil, nil] unless limit_config && limit_config[:per]

      period_type = limit_config[:per] || PricingPlans::Registry.configuration.period_cycle
      @period_window_cache[key] = PeriodCalculator.window_for_period_type(@plan_owner, period_type)
    end

    # Full limit status hash - cached, computed from other cached values
    def limit_status(limit_key)
      key = limit_key.to_sym
      return @limit_status_cache[key] if @limit_status_cache.key?(key)

      @limit_status_cache[key] = compute_limit_status(limit_key)
    end

    # Severity for a single limit - computed from cached data
    def severity_for(limit_key)
      key = limit_key.to_sym
      return @severity_cache[key] if @severity_cache.key?(key)

      @severity_cache[key] = compute_severity(limit_key)
    end

    # Highest severity across multiple limits
    def highest_severity_for(*limit_keys)
      keys = limit_keys.flatten
      per_key = keys.map { |k| severity_for(k) }

      return :blocked if per_key.include?(:blocked)
      return :grace if per_key.include?(:grace)
      return :at_limit if per_key.include?(:at_limit)
      per_key.include?(:warning) ? :warning : :ok
    end

    # Message for a single limit
    def message_for(limit_key)
      st = limit_status(limit_key)
      return nil unless st[:configured]

      severity = severity_for(limit_key)
      return nil if severity == :ok

      cfg = PricingPlans.configuration
      current_usage = st[:current_usage]
      limit_amount = st[:limit_amount]
      ends_at = st[:grace_ends_at]

      if cfg.message_builder
        context = case severity
                  when :blocked then :over_limit
                  when :grace then :grace
                  when :at_limit then :at_limit
                  else :warning
                  end
        begin
          custom = cfg.message_builder.call(
            context: context,
            limit_key: limit_key,
            current_usage: current_usage,
            limit_amount: limit_amount,
            grace_ends_at: ends_at
          )
          return custom if custom
        rescue StandardError
          # fall through to defaults
        end
      end

      noun = begin
        PricingPlans.noun_for(limit_key)
      rescue StandardError
        "limit"
      end

      case severity
      when :blocked
        if limit_amount.is_a?(Numeric)
          "You've gone over your #{noun} for #{limit_key.to_s.humanize.downcase} (#{current_usage}/#{limit_amount}). Please upgrade your plan."
        else
          "You've gone over your #{noun} for #{limit_key.to_s.humanize.downcase}. Please upgrade your plan."
        end
      when :grace
        deadline = ends_at ? ", and your grace period ends #{ends_at.strftime('%B %d at %I:%M%p')}" : ""
        if limit_amount.is_a?(Numeric)
          "Heads up! You're currently over your #{noun} for #{limit_key.to_s.humanize.downcase} (#{current_usage}/#{limit_amount})#{deadline}. Please upgrade soon to avoid any interruptions."
        else
          "Heads up! You're currently over your #{noun} for #{limit_key.to_s.humanize.downcase}#{deadline}. Please upgrade soon to avoid any interruptions."
        end
      when :at_limit
        if limit_amount.is_a?(Numeric)
          "You've reached your #{noun} for #{limit_key.to_s.humanize.downcase} (#{current_usage}/#{limit_amount}). Upgrade your plan to unlock more."
        else
          "You're at the maximum allowed for #{limit_key.to_s.humanize.downcase}. Want more? Consider upgrading your plan."
        end
      else # :warning
        if limit_amount.is_a?(Numeric)
          "You're getting close to your #{noun} for #{limit_key.to_s.humanize.downcase} (#{current_usage}/#{limit_amount}). Keep an eye on your usage, or upgrade your plan now to stay ahead."
        else
          "You're getting close to your #{noun} for #{limit_key.to_s.humanize.downcase}. Keep an eye on your usage, or upgrade your plan now to stay ahead."
        end
      end
    end

    # Overage for a limit
    def overage_for(limit_key)
      st = limit_status(limit_key)
      return 0 unless st[:configured]

      allowed = st[:limit_amount]
      current = st[:current_usage].to_i
      return 0 unless allowed.is_a?(Numeric)

      [current - allowed.to_i, 0].max
    end

    # ========== PRIVATE HELPERS ==========

    private

    # Cached enforcement state lookup
    def enforcement_state(limit_key)
      key = limit_key.to_sym
      @enforcement_state_cache ||= {}
      return @enforcement_state_cache[key] if @enforcement_state_cache.key?(key)

      @enforcement_state_cache[key] = EnforcementState.find_by(
        plan_owner: @plan_owner,
        limit_key: limit_key.to_s
      )
    end

    # Returns nil if state is stale for the current period window (for per-period limits).
    # Destroys stale states to prevent database accumulation over time.
    def fresh_enforcement_state(limit_key)
      key = limit_key.to_sym
      @fresh_enforcement_state_cache ||= {}
      return @fresh_enforcement_state_cache[key] if @fresh_enforcement_state_cache.key?(key)

      state = enforcement_state(limit_key)
      return @fresh_enforcement_state_cache[key] = nil unless state

      limit_config = limit_config_for(limit_key)
      unless limit_config && limit_config[:per]
        return @fresh_enforcement_state_cache[key] = state
      end

      # For per-period limits, check if state is stale using cached period window
      period_start, _ = period_window_for(limit_key)
      return @fresh_enforcement_state_cache[key] = state unless period_start

      window_start_epoch = state.data&.dig("window_start_epoch")
      current_epoch = period_start.to_i

      stale = (state.exceeded_at && state.exceeded_at < period_start) ||
              (window_start_epoch && window_start_epoch < current_epoch) ||
              (window_start_epoch && window_start_epoch != current_epoch)

      if stale
        # State is stale - destroy it and return nil (consistent with GraceManager behavior)
        state.destroy!
        @fresh_enforcement_state_cache[key] = nil
      else
        @fresh_enforcement_state_cache[key] = state
      end
    end

    def compute_limit_status(limit_key)
      limit_config = limit_config_for(limit_key)
      return { configured: false } unless limit_config

      usage = current_usage_for(limit_key)
      limit_amount = limit_config[:to]
      percent = percent_used_for(limit_key)
      grace = grace_active?(limit_key)
      blocked = should_block?(limit_key)

      {
        configured: true,
        limit_key: limit_key.to_sym,
        limit_amount: limit_amount,
        current_usage: usage,
        percent_used: percent,
        grace_active: grace,
        grace_ends_at: grace_ends_at(limit_key),
        blocked: blocked,
        after_limit: limit_config[:after_limit],
        per: !!limit_config[:per]
      }
    end

    def compute_severity(limit_key)
      st = limit_status(limit_key)
      return :ok unless st[:configured]

      lim = st[:limit_amount]
      cur = st[:current_usage]

      # Grace has priority over other non-blocked statuses
      return :grace if st[:grace_active]

      # Numeric limit semantics - severity is based on usage vs limit,
      # NOT on the :blocked flag (which is about enforcement, not severity)
      if lim != :unlimited && lim.to_i > 0
        return :blocked if cur.to_i > lim.to_i
        return :at_limit if cur.to_i == lim.to_i
      end

      # Otherwise, warning based on thresholds
      percent = st[:percent_used].to_f
      warn_thresholds = warning_thresholds(limit_key)
      return :ok if warn_thresholds.empty?

      highest_warn = warn_thresholds.max.to_f * 100.0
      (percent >= highest_warn && highest_warn.positive?) ? :warning : :ok
    end
  end
end
