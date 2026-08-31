# frozen_string_literal: true

require "test_helper"

class PaySupportTest < ActiveSupport::TestCase
  Subscription = Struct.new(:active?, :on_trial?, :on_grace_period?, :past_due?, :ended?, keyword_init: true)

  def test_subscription_active_for_handles_objects_without_id
    refute PricingPlans::PaySupport.subscription_active_for?(Object.new)
  end

  def test_current_subscription_for_handles_objects_without_id
    assert_nil PricingPlans::PaySupport.current_subscription_for(Object.new)
  end

  def test_past_due_is_current_while_unpaid_and_canceled_are_not
    past_due = subscription_with(past_due: true)
    unpaid = subscription_with
    canceled = subscription_with

    assert PricingPlans::PaySupport.subscription_current?(past_due)
    refute PricingPlans::PaySupport.subscription_current?(unpaid)
    refute PricingPlans::PaySupport.subscription_current?(canceled)
  end

  def test_an_ended_subscription_cannot_remain_current_from_a_stale_past_due_status
    ended = subscription_with(past_due: true, ended: true)

    refute PricingPlans::PaySupport.subscription_current?(ended)
  end

  def test_owner_subscribed_wrapper_cannot_recurse_into_pay_support
    owner = Object.new
    owner.define_singleton_method(:subscribed?) do
      PricingPlans::PaySupport.subscription_active_for?(self)
    end

    refute PricingPlans::PaySupport.subscription_active_for?(owner)
  end

  private

  def subscription_with(active: false, trial: false, grace: false, past_due: false, ended: false)
    Subscription.new(
      active?: active,
      on_trial?: trial,
      on_grace_period?: grace,
      past_due?: past_due,
      ended?: ended
    )
  end
end
