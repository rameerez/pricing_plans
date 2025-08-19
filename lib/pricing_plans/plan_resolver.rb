# frozen_string_literal: true

module PricingPlans
  class PlanResolver
    class << self
      def effective_plan_for(plan_owner)
        # 1. Check Pay subscription status first (no app-specific gate required)
        if PaySupport.pay_available?
          plan_from_pay = resolve_plan_from_pay(plan_owner)
          return plan_from_pay if plan_from_pay
        end

        # 2. Check manual assignment
        if plan_owner.respond_to?(:id)
          assignment = Assignment.find_by(
            plan_owner_type: plan_owner.class.name,
            plan_owner_id: plan_owner.id
          )
          return Registry.plan(assignment.plan_key) if assignment
        end

        # 3. Fall back to default plan
        Registry.default_plan
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
        return nil unless plan_owner.respond_to?(:subscribed?) ||
                          plan_owner.respond_to?(:on_trial?) ||
                          plan_owner.respond_to?(:on_grace_period?) ||
                          plan_owner.respond_to?(:subscriptions)

        # Check if plan_owner has active subscription, trial, or grace period
        if PaySupport.subscription_active_for?(plan_owner)
          subscription = PaySupport.current_subscription_for(plan_owner)
          return nil unless subscription

          # Map processor plan to our plan
          processor_plan = subscription.processor_plan
          return plan_from_processor_plan(processor_plan) if processor_plan
        end

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
