# frozen_string_literal: true

module PricingPlans
  module PaySupport
    module_function

    def pay_available?
      defined?(Pay)
    end

    def subscription_active_for?(billable)
      return false unless billable

      individual_active = (billable.respond_to?(:subscribed?) && billable.subscribed?) ||
                          (billable.respond_to?(:on_trial?) && billable.on_trial?) ||
                          (billable.respond_to?(:on_grace_period?) && billable.on_grace_period?)
      return true if individual_active

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

    def current_subscription_for(billable)
      return nil unless pay_available?
      return nil unless billable.respond_to?(:subscription) || billable.respond_to?(:subscriptions)

      subscription = billable.respond_to?(:subscription) ? billable.subscription : nil
      return subscription if subscription && (
        (subscription.respond_to?(:active?) && subscription.active?) ||
        (subscription.respond_to?(:on_trial?) && subscription.on_trial?) ||
        (subscription.respond_to?(:on_grace_period?) && subscription.on_grace_period?)
      )

      if billable.respond_to?(:subscriptions)
        billable.subscriptions&.find do |sub|
          (sub.respond_to?(:on_trial?) && sub.on_trial?) ||
            (sub.respond_to?(:on_grace_period?) && sub.on_grace_period?) ||
            (sub.respond_to?(:active?) && sub.active?)
        end
      end
    end
  end
end
