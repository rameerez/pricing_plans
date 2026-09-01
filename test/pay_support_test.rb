# frozen_string_literal: true

require "test_helper"

class PaySupportTest < ActiveSupport::TestCase
  Subscription = Struct.new(
    :active?, :on_trial?, :on_grace_period?, :past_due?, :ended?, :pause_active?,
    keyword_init: true
  )

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

  def test_an_effective_pause_cannot_remain_current_from_a_stale_past_due_status
    paused = subscription_with(past_due: true, pause_active: true)
    scheduled_pause = subscription_with(past_due: true, grace: true)

    refute PricingPlans::PaySupport.subscription_current?(paused)
    assert PricingPlans::PaySupport.subscription_current?(scheduled_pause)
  end

  def test_owner_subscribed_wrapper_cannot_recurse_into_pay_support
    owner = Object.new
    owner.define_singleton_method(:subscribed?) do
      PricingPlans::PaySupport.subscription_active_for?(self)
    end

    refute PricingPlans::PaySupport.subscription_active_for?(owner)
  end

  def test_active_record_payment_processor_is_read_without_calling_side_effectful_override
    processor = Struct.new(:subscriptions).new([subscription_with(active: true)])
    association = Struct.new(:reader).new(processor)
    owner_class = Class.new do
      define_singleton_method(:reflect_on_association) do |name|
        Object.new if name == :payment_processor
      end
    end
    owner = owner_class.new
    owner.define_singleton_method(:payment_processor) { raise "must not invoke Pay's side-effectful reader" }
    owner.define_singleton_method(:association) do |name|
      raise unless name == :payment_processor

      association
    end

    assert_equal [processor.subscriptions.first], PricingPlans::PaySupport.current_subscriptions_for(owner)
  end

  def test_poro_payment_processor_adapters_still_use_the_public_reader
    processor = Struct.new(:subscriptions).new([subscription_with(active: true)])
    owner = Object.new
    owner.define_singleton_method(:payment_processor) { processor }

    assert_equal [processor.subscriptions.first], PricingPlans::PaySupport.current_subscriptions_for(owner)
  end

  private

  def subscription_with(active: false, trial: false, grace: false, past_due: false, ended: false,
    pause_active: false)
    Subscription.new(
      active?: active,
      on_trial?: trial,
      on_grace_period?: grace,
      past_due?: past_due,
      ended?: ended,
      pause_active?: pause_active
    )
  end
end
