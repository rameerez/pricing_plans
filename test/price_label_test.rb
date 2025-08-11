# frozen_string_literal: true

require "test_helper"

class PriceLabelTest < ActiveSupport::TestCase
  def setup
    super
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        stripe_price "price_abc"
      end
    end
    @plan = PricingPlans::Registry.plan(:pro)
  end

  def test_price_label_falls_back_when_no_stripe
    # No Stripe constant defined; should fall back to Contact for stripe_price plans
    assert_equal "Contact", @plan.price_label
  end

  def test_price_label_auto_fetches_from_stripe_when_available
    # Define a minimal Stripe stub only for this test
    stripe_mod = Module.new
    price_class = Class.new do
      def self.retrieve(_id)
        recurring = Struct.new(:interval).new("month")
        Struct.new(:unit_amount, :recurring).new(2_900, recurring)
      end
    end
    stripe_mod.const_set(:Price, price_class)
    Object.const_set(:Stripe, stripe_mod)

    begin
      label = @plan.price_label
      assert_match(/\$29(\.0)?\/mon/, label)
    ensure
      Object.send(:remove_const, :Stripe)
    end
  end
end
