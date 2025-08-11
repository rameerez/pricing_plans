# frozen_string_literal: true

module PricingPlans
  class Registry
    class << self
      def build_from_configuration(configuration)
        @plans = configuration.plans.dup
        @configuration = configuration
        @event_handlers = configuration.event_handlers.dup

        validate_registry!
        lint_usage_credits_integration!
        attach_billable_helpers!
        attach_pending_association_limits!

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

        value = @configuration.billable_class
        return nil unless value

        case value
        when String
          value.constantize
        when Class
          value
        else
          raise ConfigurationError, "billable_class must be a string or class"
        end
      end

      def default_plan
        return nil unless @configuration
        plan(@configuration.default_plan)
      end

      def highlighted_plan
        return nil unless @configuration
        if @configuration.highlighted_plan
          return plan(@configuration.highlighted_plan)
        end
        # Fallback to plan flagged highlighted in DSL
        plans.values.find(&:highlighted?)
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

      def attach_billable_helpers!
        klass = billable_class rescue nil
        return unless klass
        return if klass.included_modules.include?(PricingPlans::Billable)
        klass.include(PricingPlans::Billable)
      rescue StandardError
        # If billable class isn't available yet, skip silently.
      end

      def attach_pending_association_limits!
        PricingPlans::AssociationLimitRegistry.flush_pending!
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
        # With single-currency credits, we only enforce separation of concerns:
        # - pricing_plans shows declared total credits per plan (cosmetic)
        # - usage_credits owns operations, costs, fulfillment, and spending
        # There is no per-operation credits declaration here anymore.
        # Still enforce that if you choose to model a metered dimension as credits in your app,
        # you should not also define a per-period limit with the same semantic key.
        credit_operation_keys = if usage_credits_available?
          UsageCredits.registry.operations.keys.map(&:to_sym) rescue []
        else
          []
        end

        plans.each do |_plan_key, plan|
          plan.limits.each do |limit_key, limit|
            next unless limit[:per] # Only per-period limits
            if credit_operation_keys.include?(limit_key.to_sym)
              raise ConfigurationError,
                "Limit '#{limit_key}' is also a usage_credits operation. Use credits (usage_credits) OR a per-period limit (pricing_plans), not both."
            end
          end
        end
      end
    end
  end
end
