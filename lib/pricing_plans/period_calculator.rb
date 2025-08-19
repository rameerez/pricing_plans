# frozen_string_literal: true

module PricingPlans
  class PeriodCalculator
    class << self
      def window_for(plan_owner, limit_key)
        plan = PlanResolver.effective_plan_for(plan_owner)
        limit_config = plan&.limit_for(limit_key)

        period_type = determine_period_type(limit_config)
        calculate_window_for_period(plan_owner, period_type)
      end

      private

      # Backward-compatible shim for tests that stub pay_available?
      def pay_available?
        PaySupport.pay_available?
      end

      def determine_period_type(limit_config)
        # First check the limit's specific per: configuration
        return limit_config[:per] if limit_config&.dig(:per)

        # Fall back to global configuration
        Registry.configuration.period_cycle
      end

      def calculate_window_for_period(plan_owner, period_type)
        case period_type
        when :billing_cycle
          billing_cycle_window(plan_owner)
        when :calendar_month, :month
          calendar_month_window
        when :calendar_week, :week
          calendar_week_window
        when :calendar_day, :day
          calendar_day_window
        when ->(x) { x.respond_to?(:call) }
          # Custom callable
          result = period_type.call(plan_owner)
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

      def billing_cycle_window(plan_owner)
        # Respect tests that stub pay availability
        return fallback_window unless pay_available?

        subscription = nil
        if plan_owner.respond_to?(:subscription)
          subscription = plan_owner.subscription
        end
        if subscription.nil? && plan_owner.respond_to?(:subscriptions)
          # Prefer a sub with explicit period anchors
          subscription = plan_owner.subscriptions.find do |sub|
            sub.respond_to?(:current_period_start) && sub.respond_to?(:current_period_end)
          end
          # Otherwise, fall back to any active/trial/grace subscription
          subscription ||= plan_owner.subscriptions.find do |sub|
            (sub.respond_to?(:active?) && sub.active?) ||
              (sub.respond_to?(:on_trial?) && sub.on_trial?) ||
              (sub.respond_to?(:on_grace_period?) && sub.on_grace_period?)
          end
        end
        subscription ||= PaySupport.current_subscription_for(plan_owner)

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

      # Removed duplicate Pay helpers; centralized in PaySupport

      def fallback_window
        # Default to calendar month if billing cycle unavailable
        calendar_month_window
      end

      def validate_custom_window!(window)
        unless window.is_a?(Array) && window.size == 2
          raise ConfigurationError, "Custom period callable must return [start_time, end_time]"
        end

        start_time, end_time = window

        unless start_time&.respond_to?(:to_time) && end_time&.respond_to?(:to_time)
          raise ConfigurationError, "Custom period window times must respond to :to_time"
        end

        begin
          # Convert explicitly to UTC to avoid Rails 8.1 to_time deprecation noise
          start_time_converted =
            if start_time.is_a?(Time)
              start_time
            elsif start_time.respond_to?(:to_time)
              start_time.to_time(:utc)
            else
              Time.parse(start_time.to_s)
            end

          end_time_converted =
            if end_time.is_a?(Time)
              end_time
            elsif end_time.respond_to?(:to_time)
              end_time.to_time(:utc)
            else
              Time.parse(end_time.to_s)
            end
          if end_time_converted <= start_time_converted
            raise ConfigurationError, "Custom period end_time must be after start_time"
          end
        rescue NoMethodError
          raise ConfigurationError, "Custom period window times must respond to :to_time"
        end
      end
    end
  end
end
