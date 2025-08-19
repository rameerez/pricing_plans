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

  def test_cta_url_resolver_prefers_default_cta_url_when_set
    PricingPlans.configuration.default_cta_url = "/pricing"
    assert_equal "/pricing", @plan.cta_url(plan_owner: @org)
  ensure
    PricingPlans.configuration.default_cta_url = nil
  end

  def test_cta_url_uses_conventional_subscribe_path_when_available
    # Simulate presence of subscribe_path in host app, but do not leak to other tests
    original_helpers = nil
    created_rails = false
    begin
      mod = Module.new do
        def self.subscribe_path(plan:, interval:)
          "/subscribe?plan=#{plan}&interval=#{interval}"
        end
      end

      if defined?(Rails)
        original_helpers = Rails.application.routes.url_helpers if Rails.application && Rails.application.routes
        Rails.application.routes.define_singleton_method(:url_helpers) { mod }
      else
        Object.const_set(:Rails, Module.new)
        created_rails = true
        app = Module.new
        app.define_singleton_method(:routes) { OpenStruct.new(url_helpers: mod) }
        Rails.define_singleton_method(:application) { OpenStruct.new(routes: app.routes) }
      end

      url = @plan.cta_url(plan_owner: @org)
      assert_equal "/subscribe?plan=pro&interval=month", url
    ensure
      if created_rails
        Object.send(:remove_const, :Rails)
      elsif original_helpers
        Rails.application.routes.define_singleton_method(:url_helpers) { original_helpers }
      end
    end
  end
end
