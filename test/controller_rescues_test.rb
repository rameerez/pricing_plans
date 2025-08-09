# frozen_string_literal: true

require "test_helper"

class ControllerRescuesTest < ActiveSupport::TestCase
  class FlashDouble
    def initialize
      @store = {}
      @now = {}
    end
    def []=(k, v)
      @store[k] = v
    end
    def [](k)
      @store[k]
    end
    def now
      @now
    end
  end

  class DummyRequest
    attr_reader :format

    def initialize(html: false, json: false)
      @format = DummyFormat.new(html: html, json: json)
    end

    class DummyFormat
      def initialize(html:, json:)
        @html = html
        @json = json
      end

      def html?
        @html
      end

      def json?
        @json
      end
    end
  end

  class DummyController
    include PricingPlans::ControllerRescues

    attr_reader :performed_action

    def initialize(request:, provide_pricing_path: true)
      @request = request
      @provide_pricing_path = provide_pricing_path
      @performed_action = nil
      # Define pricing_path helper only when requested
      if @provide_pricing_path
        define_singleton_method(:pricing_path) { "/pricing" }
      end
    end

    def request
      @request
    end

    def redirect_to(path, **kwargs)
      @performed_action = { action: :redirect_to, path: path, kwargs: kwargs, flash: flash }
    end

    def render(**kwargs)
      @performed_action = { action: :render, kwargs: kwargs, flash: flash }
    end

    def head(status)
      @performed_action = { action: :head, status: status }
    end

    def flash
      @flash ||= FlashDouble.new
    end

    # Expose the private handler for testing
    def handle!(error)
      send(:handle_pricing_plans_feature_denied, error)
    end
  end

  def test_html_redirects_to_pricing_path_with_message
    controller = DummyController.new(request: DummyRequest.new(html: true), provide_pricing_path: true)
    error = PricingPlans::FeatureDenied.new("Upgrade to Pro to access Api access")

    controller.handle!(error)

    action = controller.performed_action
    assert_equal :redirect_to, action[:action]
    assert_equal "/pricing", action[:path]
    assert_equal :see_other, action[:kwargs][:status]
    # Handler surfaces the provided message in flash
    assert_match(/upgrade to pro/i, action[:flash][:alert])
  end

  def test_html_without_pricing_path_renders_forbidden_plain
    controller = DummyController.new(request: DummyRequest.new(html: true), provide_pricing_path: false)
    error = PricingPlans::FeatureDenied.new("Feature not available")

    controller.handle!(error)

    action = controller.performed_action
    assert_equal :render, action[:action]
    assert_equal :forbidden, action[:kwargs][:status]
    assert_equal "Feature not available", action[:kwargs][:plain]
    assert_match(/feature not available/i, action[:flash].now[:alert].to_s)
  end

  def test_json_renders_error_payload_with_403
    controller = DummyController.new(request: DummyRequest.new(json: true))
    error = PricingPlans::FeatureDenied.new("Access denied")

    controller.handle!(error)

    action = controller.performed_action
    assert_equal :render, action[:action]
    assert_equal :forbidden, action[:kwargs][:status]
    assert_equal({ error: "Access denied" }, action[:kwargs][:json].slice(:error))
  end

  def test_fallback_renders_json_403_when_format_unknown
    # Neither html nor json → default to json 403
    controller = DummyController.new(request: DummyRequest.new)
    error = PricingPlans::FeatureDenied.new("Denied")

    controller.handle!(error)

    action = controller.performed_action
    assert_equal :render, action[:action]
    assert_equal :forbidden, action[:kwargs][:status]
    assert_equal({ error: "Denied" }, action[:kwargs][:json])
  end
end
