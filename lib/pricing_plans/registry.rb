# frozen_string_literal: true

module PricingPlans
  class Registry
    class << self
      def build_from_configuration(configuration)
        @plans = configuration.plans.dup
        @configuration = configuration
        @event_handlers = configuration.event_handlers.dup
        
        validate_registry!
        lint_usage_credits_integration! if usage_credits_available?
        
        self
      end
      
      def clear!
        @plans = nil
        @configuration = nil
        @event_handlers = nil
      end
      
      def plans
        @plans || {}
      end
      
      def plan(key)
        plan_obj = plans[key.to_sym]
        raise PlanNotFoundError, "Plan #{key} not found" unless plan_obj
        plan_obj
      end
      
      def plan_exists?(key)
        plans.key?(key.to_sym)
      end
      
      def configuration
        @configuration
      end
      
      def event_handlers
        @event_handlers || { warning: {}, grace_start: {}, block: {} }
      end
      
      def billable_class
        return nil unless @configuration
        
        case @configuration.billable_class
        when String
          @configuration.billable_class.constantize
        when Class
          @configuration.billable_class
        else
          raise ConfigurationError, "billable_class must be a string or class"
        end
      end
      
      def default_plan
        return nil unless @configuration
        plan(@configuration.default_plan)
      end
      
      def highlighted_plan
        return nil unless @configuration&.highlighted_plan
        plan(@configuration.highlighted_plan)
      end
      
      def emit_event(event_type, limit_key, *args)
        handler = event_handlers.dig(event_type, limit_key)
        handler&.call(*args)
      end
      
      private
      
      def validate_registry!
        # Check for duplicate stripe price IDs
        stripe_prices = plans.values
          .map(&:stripe_price)
          .compact
          .flat_map do |sp|
            case sp
            when String
              [sp]
            when Hash
              # Extract all price ID values from the hash
              [sp[:id], sp[:month], sp[:year]].compact
            else
              []
            end
          end
        
        duplicates = stripe_prices.group_by(&:itself).select { |_, v| v.size > 1 }.keys
        if duplicates.any?
          raise ConfigurationError, "Duplicate Stripe price IDs found: #{duplicates.join(', ')}"
        end
        
        # Validate limit configurations
        validate_limit_consistency!
      end
      
      def validate_limit_consistency!
        all_limits = plans.values.flat_map do |plan|
          plan.limits.map { |key, limit| [plan.key, key, limit] }
        end
        
        # Group by limit key to check consistency
        limit_groups = all_limits.group_by { |_, limit_key, _| limit_key }
        
        limit_groups.each do |limit_key, limit_configs|
          # Filter out unlimited limits from consistency check
          non_unlimited_configs = limit_configs.reject { |_, _, limit| limit[:to] == :unlimited }
          
          # Check that all non-unlimited plans with the same limit key use consistent per: configuration
          per_values = non_unlimited_configs.map { |_, _, limit| limit[:per] }.uniq
          
          # Remove nil values to check if there are mixed per/non-per configurations
          non_nil_per_values = per_values.compact
          
          # If we have both nil and non-nil per values, that's inconsistent
          # If we have multiple different non-nil per values, that's also inconsistent
          has_nil = per_values.include?(nil)
          has_non_nil = non_nil_per_values.any?
          
          if (has_nil && has_non_nil) || non_nil_per_values.size > 1
            raise ConfigurationError, 
              "Inconsistent 'per' configuration for limit '#{limit_key}': #{per_values.compact}"
          end
        end
      end
      
      def usage_credits_available?
        defined?(UsageCredits)
      end
      
      def lint_usage_credits_integration!
        # Check for collisions between per-period limits and credits
        credit_operations = if usage_credits_available?
          UsageCredits.registry.operations.keys rescue []
        else
          []
        end
        
        plans.each do |plan_key, plan|
          plan.credit_inclusions.each do |operation_key, inclusion|
            # Check if operation exists in usage_credits
            unless credit_operations.include?(operation_key)
              warn "WARNING: Plan #{plan_key} includes_credits for operation '#{operation_key}' " \
                   "but this operation is not defined in usage_credits"
            end
            
            # Check for collision with per-period limits
            limit = plan.limit_for(operation_key)
            if limit && limit[:per]
              raise ConfigurationError,
                "Plan #{plan_key} defines both includes_credits and a per-period limit for '#{operation_key}'. " \
                "Use either credits (via usage_credits gem) OR per-period limits, not both."
            end
          end
          
          # Check the opposite - per-period limits that might conflict with credits
          plan.limits.each do |limit_key, limit|
            next unless limit[:per] # Only per-period limits
            
            if credit_operations.include?(limit_key)
              # Check if any plan has credit inclusions for this operation
              has_credit_inclusion = plans.values.any? do |other_plan|
                other_plan.credit_inclusion_for(limit_key)
              end
              
              if has_credit_inclusion
                raise ConfigurationError,
                  "Limit '#{limit_key}' is defined as both a per-period limit and has credit inclusions. " \
                  "Use either credits (via usage_credits gem) OR per-period limits, not both."
              end
            end
          end
        end
      end
    end
  end
end