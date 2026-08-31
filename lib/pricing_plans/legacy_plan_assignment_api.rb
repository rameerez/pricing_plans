# frozen_string_literal: true

module PricingPlans
  # Compatibility boundary for assignment-era APIs whose names do not make it
  # clear that every persisted assignment is a pricing plan override.
  #
  # Keep all warnings and the default-plan safety policy here so every legacy
  # entry point behaves identically. New code should bypass this class and use
  # the explicit override APIs.
  class LegacyPlanAssignmentApi
    class << self
      def create_or_update_override!(plan_owner, plan_key, source:, called_method_name:)
        handle_deprecated_assignment_call!(plan_key, called_method_name)

        Assignment.create_or_update_pricing_plan_override_for!(
          plan_owner,
          plan_key,
          source: source
        )
      end

      def clear_override!(plan_owner, called_method_name:)
        PricingPlans.deprecator.warn(
          "`#{called_method_name}` is deprecated because its name does not make clear " \
          "that it only clears a persistent pricing plan override. " \
          "Use `clear_pricing_plan_override!` instead."
        )

        Assignment.clear_pricing_plan_override_for!(plan_owner)
      end

      private

      def handle_deprecated_assignment_call!(plan_key, called_method_name)
        if configured_default_plan_key?(plan_key)
          handle_deprecated_default_plan_assignment!(plan_key, called_method_name)
        else
          warn_about_deprecated_assignment_api(called_method_name)
        end
      end

      def configured_default_plan_key?(plan_key)
        default_plan_key = Registry.default_plan&.key
        default_plan_key && plan_key.to_s == default_plan_key.to_s
      end

      def handle_deprecated_default_plan_assignment!(plan_key, called_method_name)
        case PricingPlans.configuration.legacy_default_plan_assignment_behavior
        when :allow
          warn_about_deprecated_assignment_api(called_method_name)
        when :warn
          PricingPlans.deprecator.warn(default_plan_assignment_message(plan_key, called_method_name))
        when :raise
          raise LegacyDefaultPlanAssignmentError.new(
            default_plan_assignment_message(plan_key, called_method_name),
            configured_default_plan_key: plan_key,
            legacy_assignment_method_name: called_method_name
          )
        else
          raise ConfigurationError,
            "legacy_default_plan_assignment_behavior must be " \
            "#{Configuration.legacy_default_plan_assignment_behaviors_description}"
        end
      end

      def warn_about_deprecated_assignment_api(called_method_name)
        PricingPlans.deprecator.warn(
          "`#{called_method_name}` is deprecated because assigning a plan creates a " \
          "persistent pricing plan override. Use `override_pricing_plan!(plan_key, " \
          "source: ...)` instead."
        )
      end

      def default_plan_assignment_message(plan_key, called_method_name)
        "`#{called_method_name}` was asked to assign the configured default plan " \
          ":#{plan_key}. That creates a persistent pricing plan override; it does not " \
          "select the normal default-plan resolution and it will take precedence over " \
          "future subscriptions. Use `override_pricing_plan!(:#{plan_key}, source: ...)` " \
          "when the override is intentional, or `clear_pricing_plan_override!` to use " \
          "normal subscription/default resolution."
      end
    end
  end
end
