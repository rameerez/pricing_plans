# frozen_string_literal: true

module PricingPlans
  class PlanResolver
    class << self
      def log_debug(message)
        puts message if PricingPlans.configuration&.debug
      end

      def effective_plan_for(plan_owner)
        log_debug "[PricingPlans::PlanResolver] effective_plan_for called for #{plan_owner.class.name}##{plan_owner.respond_to?(:id) ? plan_owner.id : 'N/A'}"

        # 1. Check manual assignment FIRST (admin overrides take precedence)
        log_debug "[PricingPlans::PlanResolver] Checking for manual assignment..."
        if plan_owner.respond_to?(:id)
          assignment = Assignment.find_by(
            plan_owner_type: plan_owner.class.name,
            plan_owner_id: plan_owner.id
          )
          if assignment
            log_debug "[PricingPlans::PlanResolver] Found manual assignment: #{assignment.plan_key}"
            return Registry.plan(assignment.plan_key)
          else
            log_debug "[PricingPlans::PlanResolver] No manual assignment found"
          end
        end

        # 2. Check Pay subscription status
        pay_available = PaySupport.pay_available?
        log_debug "[PricingPlans::PlanResolver] PaySupport.pay_available? = #{pay_available}"
        log_debug "[PricingPlans::PlanResolver] defined?(Pay) = #{defined?(Pay)}"

        if pay_available
          log_debug "[PricingPlans::PlanResolver] Calling resolve_plan_from_pay..."
          plan_from_pay = resolve_plan_from_pay(plan_owner)
          log_debug "[PricingPlans::PlanResolver] resolve_plan_from_pay returned: #{plan_from_pay ? plan_from_pay.key : 'nil'}"
          return plan_from_pay if plan_from_pay
        end

        # 3. Fall back to default plan
        default = Registry.default_plan
        log_debug "[PricingPlans::PlanResolver] Returning default plan: #{default ? default.key : 'nil'}"
        default
      end

      def plan_key_for(plan_owner)
        effective_plan_for(plan_owner)&.key
      end

      def assign_plan_manually!(plan_owner, plan_key, source: "manual")
        Assignment.assign_plan_to(plan_owner, plan_key, source: source)
      end

      def remove_manual_assignment!(plan_owner)
        Assignment.remove_assignment_for(plan_owner)
      end

      private

      # Backward-compatible shim for tests that stub pay_available?
      def pay_available?
        PaySupport.pay_available?
      end

      def resolve_plan_from_pay(plan_owner)
        log_debug "[PricingPlans::PlanResolver] resolve_plan_from_pay: checking if plan_owner has payment_processor or Pay methods..."

        # Check if plan_owner has payment_processor (preferred) or Pay methods directly (fallback)
        has_payment_processor = plan_owner.respond_to?(:payment_processor)
        has_pay_methods = plan_owner.respond_to?(:subscribed?) ||
                          plan_owner.respond_to?(:on_trial?) ||
                          plan_owner.respond_to?(:on_grace_period?) ||
                          plan_owner.respond_to?(:subscriptions)

        log_debug "[PricingPlans::PlanResolver] has_payment_processor? #{has_payment_processor}"
        log_debug "[PricingPlans::PlanResolver] has_pay_methods? #{has_pay_methods}"

        # PaySupport will handle both payment_processor and direct Pay methods
        return nil unless has_payment_processor || has_pay_methods

        # Check if plan_owner has active subscription, trial, or grace period
        log_debug "[PricingPlans::PlanResolver] Calling PaySupport.subscription_active_for?..."
        is_active = PaySupport.subscription_active_for?(plan_owner)
        log_debug "[PricingPlans::PlanResolver] subscription_active_for? returned: #{is_active}"

        if is_active
          log_debug "[PricingPlans::PlanResolver] Calling PaySupport.current_subscription_for..."
          subscription = PaySupport.current_subscription_for(plan_owner)
          log_debug "[PricingPlans::PlanResolver] current_subscription_for returned: #{subscription ? subscription.class.name : 'nil'}"
          return nil unless subscription

          # Map processor plan to our plan
          processor_plan = subscription.processor_plan
          log_debug "[PricingPlans::PlanResolver] subscription.processor_plan = #{processor_plan.inspect}"

          if processor_plan
            matched_plan = plan_from_processor_plan(processor_plan)
            log_debug "[PricingPlans::PlanResolver] plan_from_processor_plan returned: #{matched_plan ? matched_plan.key : 'nil'}"
            return matched_plan
          end
        end

        log_debug "[PricingPlans::PlanResolver] resolve_plan_from_pay returning nil"
        nil
      end

      def plan_from_processor_plan(processor_plan)
        # Look through all plans to find one matching this Stripe price
        Registry.plans.values.find do |plan|
          stripe_price = plan.stripe_price
          next unless stripe_price

          case stripe_price
          when String
            stripe_price == processor_plan
          when Hash
            stripe_price[:id] == processor_plan ||
            stripe_price[:month] == processor_plan ||
            stripe_price[:year] == processor_plan ||
            stripe_price.values.include?(processor_plan)
          else
            false
          end
        end
      end
    end
  end
end
