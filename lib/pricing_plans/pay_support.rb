# frozen_string_literal: true

module PricingPlans
  module PaySupport
    module_function

    def pay_available?
      defined?(Pay)
    end

    def log_debug(message)
      puts message if PricingPlans.configuration&.debug
    end

    def subscription_active_for?(plan_owner)
      return false unless plan_owner

      log_debug "[PricingPlans::PaySupport] subscription_active_for? called for #{plan_owner.class.name}##{plan_owner.id}"

      # Prefer Pay's official API on the payment_processor
      if plan_owner.respond_to?(:payment_processor) && (pp = plan_owner.payment_processor)
        log_debug "[PricingPlans::PaySupport] payment_processor found: #{pp.class.name}##{pp.id}"

        # Check all subscriptions, not just the default-named one
        # Note: Don't call pp.subscribed?() without a name parameter, as it defaults to
        # checking only for subscriptions named Pay.default_product_name (usually "default")
        if pp.respond_to?(:subscriptions)
          subs = pp.subscriptions
          log_debug "[PricingPlans::PaySupport] subscriptions relation: #{subs.class.name}, count: #{subs.count}"

          # Force array conversion to ensure we iterate through all subscriptions
          # Some ActiveRecord relations might not enumerate properly in boolean context
          subs_array = subs.respond_to?(:to_a) ? subs.to_a : subs
          log_debug "[PricingPlans::PaySupport] subscriptions array size: #{subs_array.size}"

          subs_array.each_with_index do |sub, idx|
            log_debug "[PricingPlans::PaySupport]   [#{idx}] Subscription: #{sub.class.name}##{sub.id}, name: #{sub.name rescue 'N/A'}, status: #{sub.status rescue 'N/A'}, active?: #{sub.active? rescue 'N/A'}, on_trial?: #{sub.on_trial? rescue 'N/A'}, on_grace_period?: #{sub.on_grace_period? rescue 'N/A'}"
          end

          result = subs_array.any? { |sub| (sub.respond_to?(:active?) && sub.active?) || (sub.respond_to?(:on_trial?) && sub.on_trial?) || (sub.respond_to?(:on_grace_period?) && sub.on_grace_period?) }
          log_debug "[PricingPlans::PaySupport] subscription_active_for? returning: #{result}"
          return result
        else
          log_debug "[PricingPlans::PaySupport] payment_processor does not respond to :subscriptions"
        end
      else
        log_debug "[PricingPlans::PaySupport] No payment_processor found or plan_owner doesn't respond to :payment_processor"
      end

      # Fallbacks for apps that surface Pay state on the owner
      individual_active = (plan_owner.respond_to?(:subscribed?) && plan_owner.subscribed?) ||
                          (plan_owner.respond_to?(:on_trial?) && plan_owner.on_trial?) ||
                          (plan_owner.respond_to?(:on_grace_period?) && plan_owner.on_grace_period?)
      log_debug "[PricingPlans::PaySupport] Fallback individual_active: #{individual_active}"
      return true if individual_active

      if plan_owner.respond_to?(:subscriptions) && (subs = plan_owner.subscriptions)
        log_debug "[PricingPlans::PaySupport] Checking plan_owner.subscriptions fallback"
        return subs.any? { |sub| (sub.respond_to?(:active?) && sub.active?) || (sub.respond_to?(:on_trial?) && sub.on_trial?) || (sub.respond_to?(:on_grace_period?) && sub.on_grace_period?) }
      end

      log_debug "[PricingPlans::PaySupport] subscription_active_for? returning false (no active subscription found)"
      false
    end

    def current_subscription_for(plan_owner)
      return nil unless pay_available?

      log_debug "[PricingPlans::PaySupport] current_subscription_for called for #{plan_owner.class.name}##{plan_owner.id}"

      # Prefer Pay's payment_processor API
      if plan_owner.respond_to?(:payment_processor) && (pp = plan_owner.payment_processor)
        log_debug "[PricingPlans::PaySupport] payment_processor found: #{pp.class.name}##{pp.id}"

        # Check all subscriptions, not just the default-named one
        # Note: Don't call pp.subscription() without a name parameter, as it defaults to
        # looking for subscriptions named Pay.default_product_name (usually "default")
        if pp.respond_to?(:subscriptions)
          subs = pp.subscriptions
          log_debug "[PricingPlans::PaySupport] subscriptions relation: #{subs.class.name}, count: #{subs.count}"

          # Force array conversion to ensure we iterate properly
          subs_array = subs.respond_to?(:to_a) ? subs.to_a : subs
          log_debug "[PricingPlans::PaySupport] subscriptions array size: #{subs_array.size}"

          found = subs_array.find do |sub|
            (sub.respond_to?(:on_trial?) && sub.on_trial?) ||
              (sub.respond_to?(:on_grace_period?) && sub.on_grace_period?) ||
              (sub.respond_to?(:active?) && sub.active?)
          end
          log_debug "[PricingPlans::PaySupport] current_subscription_for found: #{found ? "#{found.class.name}##{found.id} (name: #{found.name})" : 'nil'}"
          return found if found
        else
          log_debug "[PricingPlans::PaySupport] payment_processor does not respond to :subscriptions"
        end
      else
        log_debug "[PricingPlans::PaySupport] No payment_processor found or plan_owner doesn't respond to :payment_processor"
      end

      # Fallbacks for apps that surface subscriptions on the owner
      if plan_owner.respond_to?(:subscription)
        log_debug "[PricingPlans::PaySupport] Checking plan_owner.subscription fallback"
        subscription = plan_owner.subscription
        if subscription && (
          (subscription.respond_to?(:active?) && subscription.active?) ||
          (subscription.respond_to?(:on_trial?) && subscription.on_trial?) ||
          (subscription.respond_to?(:on_grace_period?) && subscription.on_grace_period?)
        )
          log_debug "[PricingPlans::PaySupport] current_subscription_for returning fallback subscription"
          return subscription
        end
      end

      if plan_owner.respond_to?(:subscriptions) && (subs = plan_owner.subscriptions)
        log_debug "[PricingPlans::PaySupport] Checking plan_owner.subscriptions fallback"
        found = subs.find do |sub|
          (sub.respond_to?(:on_trial?) && sub.on_trial?) ||
            (sub.respond_to?(:on_grace_period?) && sub.on_grace_period?) ||
            (sub.respond_to?(:active?) && sub.active?)
        end
        log_debug "[PricingPlans::PaySupport] current_subscription_for found in fallback: #{found ? "#{found.class.name}##{found.id}" : 'nil'}"
        return found if found
      end

      log_debug "[PricingPlans::PaySupport] current_subscription_for returning nil"
      nil
    end
  end
end
