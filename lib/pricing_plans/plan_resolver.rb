# frozen_string_literal: true

module PricingPlans
  class PlanResolver
    class << self
      def effective_plan_for(billable)
        # 1. Check Pay subscription status first (no app-specific gate required)
        if PaySupport.pay_available?
          plan_from_pay = resolve_plan_from_pay(billable)
          return plan_from_pay if plan_from_pay
        end

        # 2. Check manual assignment
        if billable.respond_to?(:id)
          assignment = Assignment.find_by(
            billable_type: billable.class.name,
            billable_id: billable.id
          )
          return Registry.plan(assignment.plan_key) if assignment
        end

        # 3. Fall back to default plan
        Registry.default_plan
      end

      def plan_key_for(billable)
        effective_plan_for(billable)&.key
      end

      def assign_plan_manually!(billable, plan_key, source: "manual")
        Assignment.assign_plan_to(billable, plan_key, source: source)
      end

      def remove_manual_assignment!(billable)
        Assignment.remove_assignment_for(billable)
      end

      private

      # Backward-compatible shim for tests that stub pay_available?
      def pay_available?
        PaySupport.pay_available?
      end

      def resolve_plan_from_pay(billable)
        return nil unless billable.respond_to?(:subscribed?) ||
                          billable.respond_to?(:on_trial?) ||
                          billable.respond_to?(:on_grace_period?) ||
                          billable.respond_to?(:subscriptions)

        # Check if billable has active subscription, trial, or grace period
        if PaySupport.subscription_active_for?(billable)
          subscription = PaySupport.current_subscription_for(billable)
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
