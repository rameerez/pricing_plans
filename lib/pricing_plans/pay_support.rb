# frozen_string_literal: true

module PricingPlans
  module PaySupport
    module_function

    def pay_available?
      defined?(Pay)
    end

    def subscription_active_for?(billable)
      return false unless billable

      # Prefer Pay's official API on the payment_processor
      if billable.respond_to?(:payment_processor) && (pp = billable.payment_processor)
        return true if (pp.respond_to?(:subscribed?) && pp.subscribed?) ||
                        (pp.respond_to?(:on_trial?) && pp.on_trial?) ||
                        (pp.respond_to?(:on_grace_period?) && pp.on_grace_period?)

        if pp.respond_to?(:subscriptions) && (subs = pp.subscriptions)
          return subs.any? { |sub| (sub.respond_to?(:active?) && sub.active?) || (sub.respond_to?(:on_trial?) && sub.on_trial?) || (sub.respond_to?(:on_grace_period?) && sub.on_grace_period?) }
        end
      end

      # Fallbacks for apps that surface Pay state on the owner
      individual_active = (billable.respond_to?(:subscribed?) && billable.subscribed?) ||
                          (billable.respond_to?(:on_trial?) && billable.on_trial?) ||
                          (billable.respond_to?(:on_grace_period?) && billable.on_grace_period?)
      return true if individual_active

      if billable.respond_to?(:subscriptions) && (subs = billable.subscriptions)
        return subs.any? { |sub| (sub.respond_to?(:active?) && sub.active?) || (sub.respond_to?(:on_trial?) && sub.on_trial?) || (sub.respond_to?(:on_grace_period?) && sub.on_grace_period?) }
      end

      false
    end

    def current_subscription_for(billable)
      return nil unless pay_available?

      # Prefer Pay's payment_processor API
      if billable.respond_to?(:payment_processor) && (pp = billable.payment_processor)
        if pp.respond_to?(:subscription)
          subscription = pp.subscription
          if subscription && (
            (subscription.respond_to?(:active?) && subscription.active?) ||
            (subscription.respond_to?(:on_trial?) && subscription.on_trial?) ||
            (subscription.respond_to?(:on_grace_period?) && subscription.on_grace_period?)
          )
            return subscription
          end
        end

        if pp.respond_to?(:subscriptions) && (subs = pp.subscriptions)
          found = subs.find do |sub|
            (sub.respond_to?(:on_trial?) && sub.on_trial?) ||
              (sub.respond_to?(:on_grace_period?) && sub.on_grace_period?) ||
              (sub.respond_to?(:active?) && sub.active?)
          end
          return found if found
        end
      end

      # Fallbacks for apps that surface subscriptions on the owner
      if billable.respond_to?(:subscription)
        subscription = billable.subscription
        if subscription && (
          (subscription.respond_to?(:active?) && subscription.active?) ||
          (subscription.respond_to?(:on_trial?) && subscription.on_trial?) ||
          (subscription.respond_to?(:on_grace_period?) && subscription.on_grace_period?)
        )
          return subscription
        end
      end

      if billable.respond_to?(:subscriptions) && (subs = billable.subscriptions)
        subs.find do |sub|
          (sub.respond_to?(:on_trial?) && sub.on_trial?) ||
            (sub.respond_to?(:on_grace_period?) && sub.on_grace_period?) ||
            (sub.respond_to?(:active?) && sub.active?)
        end
      end
    end
  end
end
