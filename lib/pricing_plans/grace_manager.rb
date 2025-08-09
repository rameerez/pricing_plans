# frozen_string_literal: true

module PricingPlans
  class GraceManager
    class << self
      def mark_exceeded!(billable, limit_key, grace_period: nil)
        with_lock(billable, limit_key) do |state|
          # Ensure state is for the current window for per-period limits
          state = ensure_fresh_state_for_current_window!(state, billable, limit_key)

          return state if state.exceeded?

          plan = PlanResolver.effective_plan_for(billable)
          limit_config = plan&.limit_for(limit_key)

          grace_period ||= limit_config&.dig(:grace) || 7.days

          state.update!(
            exceeded_at: Time.current,
            data: state.data.merge(
              "grace_period" => grace_period.to_i,

              # Track window for per-period limits
              "window_start_epoch" => current_window_start_if_per(limit_config, billable, limit_key)&.to_i,
              "window_end_epoch" => current_window_end_if_per(limit_config, billable, limit_key)&.to_i
            )
          )

          # Emit grace start event
          emit_grace_start_event(billable, limit_key, state.grace_ends_at)

          state
        end
      end

      def grace_active?(billable, limit_key)
        state = fresh_state_or_nil(billable, limit_key)
        return false unless state&.exceeded?
        !state.grace_expired?
      end

      def should_block?(billable, limit_key)
        plan = PlanResolver.effective_plan_for(billable)
        limit_config = plan&.limit_for(limit_key)
        return false unless limit_config

        after_limit = limit_config[:after_limit]
        return false if after_limit == :just_warn
        return true if after_limit == :block_usage

        # For :grace_then_block, check if grace period expired
        state = fresh_state_or_nil(billable, limit_key)
        return false unless state&.exceeded?

        state.grace_expired?
      end

      def mark_blocked!(billable, limit_key)
        with_lock(billable, limit_key) do |state|
          state = ensure_fresh_state_for_current_window!(state, billable, limit_key)
          return state if state.blocked?

          state.update!(blocked_at: Time.current)

          # Emit block event
          emit_block_event(billable, limit_key)

          state
        end
      end

      def maybe_emit_warning!(billable, limit_key, threshold)
        with_lock(billable, limit_key) do |state|
          state = ensure_fresh_state_for_current_window!(state, billable, limit_key)
          last_threshold = state.last_warning_threshold || 0.0

          # Only emit if this is a higher threshold than last time
          if threshold > last_threshold
            plan = PlanResolver.effective_plan_for(billable)
            limit_config = plan&.limit_for(limit_key)
            window_start_epoch = nil
            window_end_epoch = nil
            if limit_config && limit_config[:per]
              period_start, period_end = PeriodCalculator.window_for(billable, limit_key)
              window_start_epoch = period_start.to_i
              window_end_epoch = period_end.to_i
            end

            state.update!(
              last_warning_threshold: threshold,
              last_warning_at: Time.current,
              data: state.data.merge(
                "window_start_epoch" => window_start_epoch,
                "window_end_epoch" => window_end_epoch
              )
            )

            emit_warning_event(billable, limit_key, threshold)
          end

          state
        end
      end

      def reset_state!(billable, limit_key)
        state = find_state(billable, limit_key)
        return unless state

        state.destroy!
      end

      def grace_ends_at(billable, limit_key)
        state = find_state(billable, limit_key)
        state&.grace_ends_at
      end

      private

      def with_lock(billable, limit_key)

        # Use row-level locking to prevent race conditions
        state = nil
        begin
          state = EnforcementState.lock.find_or_create_by!(
            billable: billable,
            limit_key: limit_key.to_s
          ) { |new_state| new_state.data = {} }
        rescue ActiveRecord::RecordNotUnique
          # Concurrent creation; fetch the locked row and proceed
          state = EnforcementState.lock.find_by!(billable: billable, limit_key: limit_key.to_s)
        end

        # Retry logic for deadlocks
        retries = 0
        begin
          yield(state)
        rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout => e
          retries += 1
          if retries < 3
            sleep(0.1 * retries)
            retry
          else
            raise e
          end
        end
      end

      def find_state(billable, limit_key)
        EnforcementState.find_by(billable: billable, limit_key: limit_key.to_s)
      end

      # Returns nil if state is stale for the current period window for per-period limits
      def fresh_state_or_nil(billable, limit_key)
        state = find_state(billable, limit_key)
        return nil unless state

        plan = PlanResolver.effective_plan_for(billable)
        limit_config = plan&.limit_for(limit_key)
        return state unless limit_config && limit_config[:per]

        period_start, _ = PeriodCalculator.window_for(billable, limit_key)
        window_start_epoch = state.data&.dig("window_start_epoch")
        current_epoch = period_start.to_i

        if stale_for_window?(state, period_start, window_start_epoch, current_epoch)
          state.destroy!
          return nil
        end
        state
      end

      def stale_for_window?(state, period_start, window_start_epoch, current_epoch)
        (state.exceeded_at && state.exceeded_at < period_start) ||
          (window_start_epoch && window_start_epoch < current_epoch) ||
          (window_start_epoch && window_start_epoch != current_epoch)
      end

      def emit_warning_event(billable, limit_key, threshold)
        Registry.emit_event(:warning, limit_key.to_sym, billable, threshold)
      end

      def emit_grace_start_event(billable, limit_key, grace_ends_at)
        Registry.emit_event(:grace_start, limit_key.to_sym, billable, grace_ends_at)
      end

      def emit_block_event(billable, limit_key)
        Registry.emit_event(:block, limit_key.to_sym, billable)
      end


      # Ensure the state aligns with the current period window for per-period limits
      def ensure_fresh_state_for_current_window!(state, billable, limit_key)
        plan = PlanResolver.effective_plan_for(billable)
        limit_config = plan&.limit_for(limit_key)
        return state unless limit_config && limit_config[:per]

        period_start, _ = PeriodCalculator.window_for(billable, limit_key)
        window_start_epoch = state.data&.dig("window_start_epoch")
        current_epoch = period_start.to_i
        if stale_for_window?(state, period_start, window_start_epoch, current_epoch)
          state.destroy!
          state = EnforcementState.lock.find_or_create_by!(billable: billable, limit_key: limit_key.to_s) { |new_state| new_state.data = {} }
        end
        state
      end

      def current_window_start_if_per(limit_config, billable, limit_key)
        return nil unless limit_config && limit_config[:per]
        PeriodCalculator.window_for(billable, limit_key).first
      end

      def current_window_end_if_per(limit_config, billable, limit_key)
        return nil unless limit_config && limit_config[:per]
        PeriodCalculator.window_for(billable, limit_key).last
      end
    end
  end
end
