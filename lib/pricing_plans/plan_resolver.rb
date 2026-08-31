# frozen_string_literal: true

module PricingPlans
  class PlanResolver
    class << self
      def log_debug(message)
        puts message if PricingPlans.configuration&.debug
      end

      def effective_plan_for(plan_owner)
        resolution_for(plan_owner).plan
      end

      def plan_key_for(plan_owner)
        resolution_for(plan_owner).plan_key
      end

      def resolution_for(plan_owner)
        log_debug "[PricingPlans::PlanResolver] resolution_for called for #{plan_owner.class.name}##{plan_owner.respond_to?(:id) ? plan_owner.id : 'N/A'}"

        assignment = pricing_plan_override_for(plan_owner)
        subscription = current_subscription_for(plan_owner, preferred_plan_key: assignment&.plan_key)

        if assignment
          log_debug "[PricingPlans::PlanResolver] Returning explicit-override resolution: #{assignment.plan_key}"
          return PlanResolution.new(
            plan: Registry.plan(assignment.plan_key),
            source: :assignment,
            assignment: assignment,
            subscription: subscription
          )
        end

        subscription_resolution = subscription_resolution_for(subscription)
        return subscription_resolution if subscription_resolution

        default = Registry.default_plan
        log_debug "[PricingPlans::PlanResolver] Returning default-backed resolution: #{default ? default.key : 'nil'}"
        PlanResolution.new(
          plan: default,
          source: :default,
          assignment: nil,
          subscription: subscription
        )
      end

      def override_pricing_plan_for!(plan_owner, plan_key, source:)
        Assignment.create_or_update_pricing_plan_override_for!(
          plan_owner,
          plan_key,
          source: source
        )
      end

      def clear_pricing_plan_override_for!(plan_owner)
        Assignment.clear_pricing_plan_override_for!(plan_owner)
      end

      def assign_plan_manually!(plan_owner, plan_key, source: "manual")
        LegacyPlanAssignmentApi.create_or_update_override!(
          plan_owner,
          plan_key,
          source: source,
          called_method_name: "PricingPlans::PlanResolver.assign_plan_manually!"
        )
      end

      def remove_manual_assignment!(plan_owner)
        LegacyPlanAssignmentApi.clear_override!(
          plan_owner,
          called_method_name: "PricingPlans::PlanResolver.remove_manual_assignment!"
        )
      end

      # Resolve a processor price identifier to the configured plan that owns
      # it. Public so entitlement provenance can verify that an underlying
      # subscription belongs to the same plan as a manual override.
      def plan_for_processor_plan(processor_plan)
        return nil if processor_plan.blank?

        Registry.plans.values.find do |plan|
          stripe_price = plan.stripe_price
          next unless stripe_price

          stripe_price.is_a?(Hash) ? stripe_price.value?(processor_plan) : stripe_price == processor_plan
        end
      end

      private

      # Backward-compatible shim for tests that stub pay_available?
      def pay_available?
        PaySupport.pay_available?
      end

      def pricing_plan_override_for(plan_owner)
        log_debug "[PricingPlans::PlanResolver] Checking for an explicit pricing plan override..."
        return nil unless plan_owner.respond_to?(:id)

        assignment = Assignment.find_by(
          PlanOwnerIdentity.conditions_for(plan_owner)
        )

        if assignment
          log_debug "[PricingPlans::PlanResolver] Found explicit pricing plan override: #{assignment.plan_key}"
        else
          log_debug "[PricingPlans::PlanResolver] No explicit pricing plan override found"
        end

        assignment
      end

      def subscription_resolution_for(subscription)
        return nil unless subscription.respond_to?(:processor_plan)

        processor_plan = subscription.processor_plan
        log_debug "[PricingPlans::PlanResolver] resolution_for subscription processor_plan = #{processor_plan.inspect}"
        plan = plan_for_processor_plan(processor_plan)
        return nil unless plan

        log_debug "[PricingPlans::PlanResolver] Returning subscription-backed resolution: #{plan.key}"
        PlanResolution.new(
          plan: plan,
          source: :subscription,
          assignment: nil,
          subscription: subscription
        )
      end

      def current_subscription_for(plan_owner, preferred_plan_key: nil)
        return nil unless plan_owner

        pay_available = pay_available?
        log_debug "[PricingPlans::PlanResolver] PaySupport.pay_available? = #{pay_available}"

        return nil unless pay_available

        subscriptions = PaySupport.current_subscriptions_for(plan_owner)
        subscription = select_subscription(subscriptions, preferred_plan_key: preferred_plan_key)
        log_debug "[PricingPlans::PlanResolver] current_subscription_for returned: #{subscription ? subscription.class.name : 'nil'}"
        subscription
      end

      def select_subscription(subscriptions, preferred_plan_key: nil)
        subscriptions = Array(subscriptions)

        if preferred_plan_key
          preferred = subscriptions.find do |subscription|
            subscription_plan = plan_for_subscription(subscription)
            subscription_plan&.key == preferred_plan_key.to_sym
          end
          return preferred if preferred
        end

        subscriptions.find { |subscription| plan_for_subscription(subscription) } || subscriptions.first
      end

      def plan_for_subscription(subscription)
        return nil unless subscription.respond_to?(:processor_plan)

        plan_for_processor_plan(subscription.processor_plan)
      end
    end
  end
end
