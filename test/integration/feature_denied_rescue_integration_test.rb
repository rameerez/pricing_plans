# frozen_string_literal: true

require "test_helper"

# A light integration-style test around the controller guards + rescues.
class FeatureDeniedRescueIntegrationTest < ActiveSupport::TestCase
  class DummyController
    include PricingPlans::ControllerGuards
    include PricingPlans::ControllerRescues

    def initialize(billable:, format: :json)
      @billable = billable
      @format = format
    end

    def current_organization
      @billable
    end

    # Minimal surface needed by the rescue module
    def request
      @request ||= Struct.new(:format).new(Format.new(@format))
    end

    class Format
      def initialize(sym)
        @sym = sym
      end
      def html?; @sym == :html; end
      def json?; @sym == :json; end
    end

    attr_reader :result

    def render(**kwargs)
      @result = { action: :render, kwargs: kwargs }
    end

    def redirect_to(path, **kwargs)
      @result = { action: :redirect_to, path: path, kwargs: kwargs, flash: @flash }
    end

    def pricing_path
      "/pricing"
    end

    def flash
      @flash ||= {}
    end

    # Simulate a before_action usage
    def gated
      enforce_api_access!(for: :current_organization)
      :ok
    rescue PricingPlans::FeatureDenied => e
      # Let the included rescue handle it
      send(:handle_pricing_plans_feature_denied, e)
    end
  end

  def setup
    super
    @org = create_organization
  end

  def test_json_gated_returns_403_payload
    controller = DummyController.new(billable: @org, format: :json)
    controller.gated
    assert_equal :render, controller.result[:action]
    assert_equal :forbidden, controller.result[:kwargs][:status]
    payload = controller.result[:kwargs][:json]
    assert_match(/upgrade|not available/i, payload[:error])
    # In our tiny controller we do not provide billable to the exception, so feature may be nil here
  end

  def test_html_gated_redirects_to_pricing
    controller = DummyController.new(billable: @org, format: :html)
    controller.gated
    assert_equal :redirect_to, controller.result[:action]
    assert_equal "/pricing", controller.result[:path]
    assert_equal :see_other, controller.result[:kwargs][:status]
    assert_match(/your current plan/i, controller.result[:flash][:alert])
  end
end
