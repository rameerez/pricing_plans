# frozen_string_literal: true

require "test_helper"

class CtaHelpersTest < ActiveSupport::TestCase

  def setup
    super
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :pro
      config.plan :pro do
        stripe_price "price_abc"
      end
    end
    @org = create_organization
    @plan = PricingPlans::Registry.plan(:pro)
  end

  def test_cta_url_setter_and_getter
    @plan.cta_url "/checkout"
    assert_equal "/checkout", @plan.cta_url
  end

  def test_cta_url_resolver_returns_nil_without_generator
    assert_nil @plan.cta_url(billable: @org)
  end

  def test_auto_cta_with_pay_generator_is_used
    called = false
    PricingPlans.configuration.auto_cta_with_pay = ->(billable, plan) do
      called = true
      "/gen-url"
    end
    url = @plan.cta_url(billable: @org)
    assert_equal "/gen-url", url
    assert called
  end
end
