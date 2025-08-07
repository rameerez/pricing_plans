# frozen_string_literal: true

module PricingPlans
  class LimitChecker
    class << self
      def within_limit?(billable, limit_key, by: 1)
        remaining_amount = remaining(billable, limit_key)
        return true if remaining_amount == :unlimited
        remaining_amount >= by
      end
      
      def remaining(billable, limit_key)
        plan = PlanResolver.effective_plan_for(billable)
        limit_config = plan&.limit_for(limit_key)
        return :unlimited unless limit_config
        
        limit_amount = limit_config[:to]
        return :unlimited if limit_amount == :unlimited
        
        current_usage = current_usage_for(billable, limit_key, limit_config)
        [0, limit_amount - current_usage].max
      end
      
      def percent_used(billable, limit_key)
        plan = PlanResolver.effective_plan_for(billable)
        limit_config = plan&.limit_for(limit_key)
        return 0.0 unless limit_config
        
        limit_amount = limit_config[:to]
        return 0.0 if limit_amount == :unlimited || limit_amount.zero?
        
        current_usage = current_usage_for(billable, limit_key, limit_config)
        [(current_usage.to_f / limit_amount) * 100, 100.0].min
      end
      
      def after_limit_action(billable, limit_key)
        plan = PlanResolver.effective_plan_for(billable)
        limit_config = plan&.limit_for(limit_key)
        return :block_usage unless limit_config
        
        limit_config[:after_limit]
      end
      
      def limit_amount(billable, limit_key)
        plan = PlanResolver.effective_plan_for(billable)
        limit_config = plan&.limit_for(limit_key)
        return :unlimited unless limit_config
        
        limit_config[:to]
      end
      
      def current_usage_for(billable, limit_key, limit_config = nil)
        limit_config ||= begin
          plan = PlanResolver.effective_plan_for(billable)
          plan&.limit_for(limit_key)
        end
        
        return 0 unless limit_config
        
        if limit_config[:per]
          # Per-period allowance - check usage table
          per_period_usage(billable, limit_key)
        else
          # Persistent cap - count live objects
          persistent_usage(billable, limit_key)
        end
      end
      
      def warning_thresholds(billable, limit_key)
        plan = PlanResolver.effective_plan_for(billable)
        limit_config = plan&.limit_for(limit_key)
        return [] unless limit_config
        
        limit_config[:warn_at] || []
      end
      
      def should_warn?(billable, limit_key)
        percent = percent_used(billable, limit_key)
        thresholds = warning_thresholds(billable, limit_key)
        
        # Find the highest threshold that has been crossed
        crossed_threshold = thresholds.select { |t| percent >= (t * 100) }.max
        return nil unless crossed_threshold
        
        # Check if we've already warned for this threshold
        state = enforcement_state(billable, limit_key)
        last_threshold = state&.last_warning_threshold
        
        # Return the threshold if this is a new higher threshold, nil otherwise
        crossed_threshold > (last_threshold || 0) ? crossed_threshold : nil
      end
      
      private
      
      def per_period_usage(billable, limit_key)
        period_start, period_end = PeriodCalculator.window_for(billable, limit_key)
        
        usage = Usage.find_by(
          billable: billable,
          limit_key: limit_key.to_s,
          period_start: period_start,
          period_end: period_end
        )
        
        usage&.used || 0
      end
      
      def persistent_usage(billable, limit_key)
        # This will be provided by the Limitable mixin
        # which registers counting logic per model
        counter = LimitableRegistry.counter_for(limit_key)
        return 0 unless counter
        
        counter.call(billable)
      end
      
      def enforcement_state(billable, limit_key)
        EnforcementState.find_by(
          billable: billable,
          limit_key: limit_key.to_s
        )
      end
    end
  end
  
  # Registry for Limitable counters
  class LimitableRegistry
    class << self
      def register_counter(limit_key, &block)
        counters[limit_key.to_sym] = block
      end
      
      def counter_for(limit_key)
        counters[limit_key.to_sym]
      end
      
      def counters
        @counters ||= {}
      end
      
      def clear!
        @counters = {}
      end
    end
  end
end