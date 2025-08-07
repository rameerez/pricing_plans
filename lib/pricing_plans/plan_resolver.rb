# frozen_string_literal: true

module PricingPlans
  class PlanResolver
    class << self
      def effective_plan_for(billable)
        # 1. Check Pay subscription status first
        if pay_available? && billable.respond_to?(:pay_enabled?) && billable.pay_enabled?
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
      
      def pay_available?
        defined?(Pay)
      end
      
      def resolve_plan_from_pay(billable)
        return nil unless billable.respond_to?(:subscribed?) || 
                         billable.respond_to?(:on_trial?) || 
                         billable.respond_to?(:on_grace_period?)
        
        # Check if billable has active subscription, trial, or grace period
        if subscription_active?(billable)
          subscription = current_subscription(billable)
          return nil unless subscription
          
          # Map processor plan to our plan
          processor_plan = subscription.processor_plan
          return plan_from_processor_plan(processor_plan) if processor_plan
        end
        
        nil
      end
      
      def subscription_active?(billable)
        # Check individual subscription status
        individual_active = (billable.respond_to?(:subscribed?) && billable.subscribed?) ||
                           (billable.respond_to?(:on_trial?) && billable.on_trial?) ||
                           (billable.respond_to?(:on_grace_period?) && billable.on_grace_period?)
        
        return true if individual_active
        
        # Also check if there's an active subscription in subscriptions array
        if billable.respond_to?(:subscriptions)
          billable.subscriptions.any? do |sub|
            (sub.respond_to?(:active?) && sub.active?) ||
            (sub.respond_to?(:on_trial?) && sub.on_trial?) ||
            (sub.respond_to?(:on_grace_period?) && sub.on_grace_period?)
          end
        else
          false
        end
      end
      
      def current_subscription(billable)
        return nil unless billable.respond_to?(:subscription)
        
        subscription = billable.subscription
        return subscription if subscription && (
          subscription.active? || 
          (subscription.respond_to?(:on_trial?) && subscription.on_trial?) ||
          (subscription.respond_to?(:on_grace_period?) && subscription.on_grace_period?)
        )
        
        # Also check for trial or grace period subscriptions
        if billable.respond_to?(:subscriptions)
          billable.subscriptions.find do |sub|
            sub.on_trial? || sub.on_grace_period? || sub.active?
          end
        end
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