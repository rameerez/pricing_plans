# frozen_string_literal: true

module PricingPlans
  class PeriodCalculator
    class << self
      def window_for(billable, limit_key)
        plan = PlanResolver.effective_plan_for(billable)
        limit_config = plan&.limit_for(limit_key)
        
        period_type = determine_period_type(limit_config)
        calculate_window_for_period(billable, period_type)
      end
      
      private
      
      def determine_period_type(limit_config)
        # First check the limit's specific per: configuration
        return limit_config[:per] if limit_config&.dig(:per)
        
        # Fall back to global configuration
        Registry.configuration.period_cycle
      end
      
      def calculate_window_for_period(billable, period_type)
        case period_type
        when :billing_cycle
          billing_cycle_window(billable)
        when :calendar_month, :month
          calendar_month_window
        when :calendar_week, :week  
          calendar_week_window
        when :calendar_day, :day
          calendar_day_window
        when ->(x) { x.respond_to?(:call) }
          # Custom callable
          result = period_type.call(billable)
          validate_custom_window!(result)
          result
        else
          # Handle ActiveSupport duration objects
          if period_type.respond_to?(:seconds)
            duration_window(period_type)
          else
            raise ConfigurationError, "Unknown period type: #{period_type}"
          end
        end
      end
      
      def billing_cycle_window(billable)
        subscription = current_subscription(billable)
        return fallback_window unless subscription
        
        # Use Pay's billing cycle anchor if available
        if subscription.respond_to?(:current_period_start) && 
           subscription.respond_to?(:current_period_end)
          [subscription.current_period_start, subscription.current_period_end]
        elsif subscription.respond_to?(:created_at)
          # Calculate from subscription creation date
          start_time = subscription.created_at
          monthly_window_from(start_time)
        else
          fallback_window
        end
      end
      
      def calendar_month_window
        now = Time.current
        start_time = now.beginning_of_month
        end_time = now.end_of_month
        [start_time, end_time]
      end
      
      def calendar_week_window
        now = Time.current
        start_time = now.beginning_of_week
        end_time = now.end_of_week
        [start_time, end_time]
      end
      
      def calendar_day_window  
        now = Time.current
        start_time = now.beginning_of_day
        end_time = now.end_of_day
        [start_time, end_time]
      end
      
      def duration_window(duration)
        now = Time.current
        start_time = now.beginning_of_day
        end_time = start_time + duration
        [start_time, end_time]
      end
      
      def monthly_window_from(anchor_date)
        now = Time.current
        
        # Find the current period based on anchor date
        months_since = ((now.year - anchor_date.year) * 12 + (now.month - anchor_date.month))
        
        start_time = anchor_date + months_since.months
        end_time = start_time + 1.month
        
        # If we've passed this period, move to the next one
        if now >= end_time
          start_time = end_time
          end_time = start_time + 1.month
        end
        
        [start_time, end_time]
      end
      
      def current_subscription(billable)
        return nil unless pay_available? && billable.respond_to?(:subscription)
        
        subscription = billable.subscription
        return subscription if subscription&.active?
        
        # Also check for trial or grace period subscriptions
        if billable.respond_to?(:subscriptions)
          billable.subscriptions.find do |sub|
            sub.on_trial? || sub.on_grace_period? || sub.active?
          end
        end
      end
      
      def pay_available?
        defined?(Pay)
      end
      
      def fallback_window
        # Default to calendar month if billing cycle unavailable
        calendar_month_window
      end
      
      def validate_custom_window!(window)
        unless window.is_a?(Array) && window.size == 2
          raise ConfigurationError, "Custom period callable must return [start_time, end_time]"
        end
        
        start_time, end_time = window
        
        unless start_time.respond_to?(:to_time) && end_time.respond_to?(:to_time)
          raise ConfigurationError, "Custom period window times must respond to :to_time"
        end
        
        if end_time.to_time <= start_time.to_time
          raise ConfigurationError, "Custom period end_time must be after start_time"
        end
      end
    end
  end
end