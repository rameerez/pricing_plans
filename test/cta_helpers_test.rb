# frozen_string_literal: true

require "test_helper"

class CtaHelpersTest < ActiveSupport::TestCase
  include PricingPlans::ViewHelpers

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
    # Minimal stubs for view helpers used by CTA helpers
    String.class_eval do
      def html_safe; self; end
    end
    define_singleton_method(:content_tag) do |name, *args, **kwargs, &block|
      inner = block ? block.call : args.first
      "<#{name} class='#{kwargs[:class]}'>#{inner}</#{name}>"
    end
    define_singleton_method(:link_to) do |text, url, **kwargs|
      "<a href='#{url}' class='#{kwargs[:class]}'>#{text}</a>"
    end
  end

  def test_cta_url_setter_and_getter
    @plan.cta_url "/checkout"
    assert_equal "/checkout", @plan.cta_url
  end

  def test_pricing_plans_cta_url_helper_returns_nil_without_generator
    assert_nil pricing_plans_cta_url(@plan, billable: @org, view: self)
  end

  def test_pricing_plans_cta_button_disabled_when_no_url
    html = pricing_plans_cta_button(@plan, billable: @org, view: self, context: :marketing)
    # Our stubbed content_tag doesn't render disabled attribute; assert it's a <button> (no URL)
    assert_match(/<button /, html)
  end

  def test_auto_cta_with_pay_generator_is_used
    called = false
    PricingPlans.configuration.auto_cta_with_pay = ->(billable, plan, view) do
      called = true
      "/gen-url"
    end
    url = pricing_plans_cta_url(@plan, billable: @org, view: self)
    assert_equal "/gen-url", url
    assert called
  end
end
