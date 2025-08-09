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
        attach_billable_helpers!

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
        plans.values.find(&:highlighted?)
      end

      def emit_event(event_type, limit_key, *args)
        handler = event_handlers.dig(event_type, limit_key)
        handler&.call(*args)
      end

      private

      def validate_registry!
        stripe_prices = plans.values
          .map(&:stripe_price)
          .compact
          .flat_map do |sp|
            case sp
            when String
              [sp]
            when Hash
              [sp[:id], sp[:month], sp[:year]].compact
            else
              []
            end
          end

        duplicates = stripe_prices.group_by(&:itself).select { |_, v| v.size > 1 }.keys
        if duplicates.any?
          raise ConfigurationError, "Duplicate Stripe price IDs found: #{duplicates.join(', ')}"
        end

        validate_limit_consistency!
      end

      def attach_billable_helpers!
        klass = billable_class rescue nil
        return unless klass
        return if klass.included_modules.include?(PricingPlans::Billable)
        klass.include(PricingPlans::Billable)
      rescue StandardError
      end

      def validate_limit_consistency!
        all_limits = plans.values.flat_map do |plan|
          plan.limits.map { |key, limit| [plan.key, key, limit] }
        end

        limit_groups = all_limits.group_by { |_, limit_key, _| limit_key }

        limit_groups.each do |limit_key, limit_configs|
          non_unlimited_configs = limit_configs.reject { |_, _, limit| limit[:to] == :unlimited }
          per_values = non_unlimited_configs.map { |_, _, limit| limit[:per] }.uniq
          non_nil_per_values = per_values.compact
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
        credit_operations = if usage_credits_available?
          UsageCredits.registry.operations.keys rescue []
        else
          []
        end

        plans.each do |plan_key, plan|
          plan.credit_inclusions.each do |operation_key, inclusion|
            unless credit_operations.include?(operation_key)
              raise ConfigurationError,
                "Plan #{plan_key} includes_credits for unknown usage_credits operation '#{operation_key}'. " \
                "Define the operation in usage_credits or remove includes_credits."
            end

            limit = plan.limit_for(operation_key)
            if limit && limit[:per]
              raise ConfigurationError,
                "Plan #{plan_key} defines both includes_credits and a per-period limit for '#{operation_key}'. " \
                "Use either credits (via usage_credits gem) OR per-period limits, not both."
            end
          end

          plan.limits.each do |limit_key, limit|
            next unless limit[:per]

            if credit_operations.include?(limit_key)
              has_credit_inclusion = plans.values.any? { |other_plan| other_plan.credit_inclusion_for(limit_key) }
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
