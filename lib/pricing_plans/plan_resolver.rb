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

        assignment = assignment_for(plan_owner)
        subscription = current_subscription_for(plan_owner)

        if assignment
          log_debug "[PricingPlans::PlanResolver] Returning assignment-backed resolution: #{assignment.plan_key}"
          return PlanResolution.new(
            plan: Registry.plan(assignment.plan_key),
            source: :assignment,
            assignment: assignment,
            subscription: subscription
          )
        end

        if subscription
          processor_plan = subscription.processor_plan
          log_debug "[PricingPlans::PlanResolver] resolution_for subscription processor_plan = #{processor_plan.inspect}"

          if processor_plan && (plan = plan_from_processor_plan(processor_plan))
            log_debug "[PricingPlans::PlanResolver] Returning subscription-backed resolution: #{plan.key}"
            return PlanResolution.new(
              plan: plan,
              source: :subscription,
              assignment: nil,
              subscription: subscription
            )
          end
        end

        default = Registry.default_plan
        log_debug "[PricingPlans::PlanResolver] Returning default-backed resolution: #{default ? default.key : 'nil'}"
        PlanResolution.new(
          plan: default,
          source: :default,
          assignment: nil,
          subscription: subscription
        )
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

      def assignment_for(plan_owner)
        log_debug "[PricingPlans::PlanResolver] Checking for manual assignment..."
        return nil unless plan_owner.respond_to?(:id)

        assignment = Assignment.find_by(
          plan_owner_type: plan_owner.class.name,
          plan_owner_id: plan_owner.id
        )

        if assignment
          log_debug "[PricingPlans::PlanResolver] Found manual assignment: #{assignment.plan_key}"
        else
          log_debug "[PricingPlans::PlanResolver] No manual assignment found"
        end

        assignment
      end

      def current_subscription_for(plan_owner)
        return nil unless plan_owner

        pay_available = pay_available?
        log_debug "[PricingPlans::PlanResolver] PaySupport.pay_available? = #{pay_available}"

        return nil unless pay_available

        subscription = PaySupport.current_subscription_for(plan_owner)
        log_debug "[PricingPlans::PlanResolver] current_subscription_for returned: #{subscription ? subscription.class.name : 'nil'}"
        subscription
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
