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

    # Whether an owner currently has a billing relationship that should keep
    # plan entitlements. Besides Pay's active/trial/grace states, this includes
    # past_due while the processor is retrying payment. Canceled and unpaid
    # subscriptions remain ineligible.
    def subscription_active_for?(plan_owner)
      return false unless plan_owner

      log_debug "[PricingPlans::PaySupport] subscription_active_for? called for #{owner_label(plan_owner)}"

      result = current_subscriptions_for(plan_owner).any?
      log_debug "[PricingPlans::PaySupport] subscription_active_for? returning: #{result}"
      result
    end

    def current_subscription_for(plan_owner)
      current_subscriptions_for(plan_owner).first
    end

    # Returns every entitlement-bearing subscription from the canonical Pay
    # customer. PlanResolver can then prefer one whose processor_plan appears
    # in the registry instead of accidentally choosing an unrelated active
    # subscription that happened to be returned first.
    def current_subscriptions_for(plan_owner)
      return [] unless plan_owner && pay_available?

      log_debug "[PricingPlans::PaySupport] current_subscriptions_for called for #{owner_label(plan_owner)}"

      processor_subscriptions = current_payment_processor_subscriptions(plan_owner)
      return processor_subscriptions unless processor_subscriptions.empty?

      subscriptions = []
      subscriptions << plan_owner.subscription if plan_owner.respond_to?(:subscription)
      subscriptions.concat(subscription_collection(plan_owner))

      current_subscriptions_in(subscriptions.compact.uniq).tap do |current|
        log_debug "[PricingPlans::PaySupport] found #{current.size} current owner subscription(s)"
      end
    end

    def subscription_current?(subscription)
      return false unless subscription
      return false if subscription.respond_to?(:ended?) && subscription.ended?

      state_predicates = %i[active? on_trial? on_grace_period? past_due?]
      state_predicates.any? do |predicate|
        subscription.respond_to?(predicate) && subscription.public_send(predicate)
      end
    end

    def subscription_collection(record)
      return [] unless record.respond_to?(:subscriptions)

      subscriptions = record.subscriptions
      return [] unless subscriptions

      subscriptions.respond_to?(:to_a) ? subscriptions.to_a : Array(subscriptions)
    end
    private_class_method :subscription_collection

    def current_payment_processor_subscriptions(plan_owner)
      return [] unless plan_owner.respond_to?(:payment_processor)

      payment_processor = plan_owner.payment_processor
      return [] unless payment_processor

      current_subscriptions_in(subscription_collection(payment_processor)).tap do |subscriptions|
        next if subscriptions.empty?

        log_debug "[PricingPlans::PaySupport] found #{subscriptions.size} current payment-processor subscription(s)"
      end
    end
    private_class_method :current_payment_processor_subscriptions

    def current_subscriptions_in(subscriptions)
      Array(subscriptions).select { |subscription| subscription_current?(subscription) }
    end
    private_class_method :current_subscriptions_in

    def owner_label(plan_owner)
      owner_id = plan_owner.respond_to?(:id) ? plan_owner.id : "N/A"
      "#{plan_owner.class.name}##{owner_id}"
    end
    private_class_method :owner_label
  end
end
