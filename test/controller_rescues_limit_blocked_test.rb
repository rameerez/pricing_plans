# frozen_string_literal: true

require "test_helper"

class ControllerRescuesLimitBlockedTest < ActiveSupport::TestCase
  class DummyController
    include PricingPlans::ControllerRescues

    attr_accessor :_request_format, :_flash, :_redirected_to, :_rendered

    def initialize
      @_request_format = :html
      @_flash = {}
      @_redirected_to = nil
      @_rendered = nil
    end

    def request
      OpenStruct.new(format: OpenStruct.new(html?: (_request_format == :html), json?: (_request_format == :json)))
    end

    def flash
      @_flash
    end

    def pricing_path
      "/pricing"
    end

    def redirect_to(path, status: :see_other, allow_other_host: false)
      @_redirected_to = [path, status, allow_other_host]
    end

    def render(status:, plain: nil, json: nil)
      @_rendered = [status, plain, json]
    end
  end

  def test_handle_pricing_plans_limit_blocked_html
    ctrl = DummyController.new
    result = PricingPlans::Result.blocked("blocked!", limit_key: :projects, billable: create_organization)
    ctrl.send(:handle_pricing_plans_limit_blocked, result)
    assert_equal ["/pricing", :see_other, false], ctrl._redirected_to
    assert_match(/blocked!/i, ctrl._flash[:alert])
  end

  def test_handle_pricing_plans_limit_blocked_html_prefers_redirect_from_metadata
    ctrl = DummyController.new
    result = PricingPlans::Result.blocked(
      "blocked!",
      limit_key: :projects,
      billable: create_organization,
      metadata: { redirect_to: "/override" }
    )
    ctrl.send(:handle_pricing_plans_limit_blocked, result)
    assert_equal ["/override", :see_other, false], ctrl._redirected_to
    assert_match(/blocked!/i, ctrl._flash[:alert])
  end

  def test_handle_pricing_plans_limit_blocked_json
    ctrl = DummyController.new
    ctrl._request_format = :json
    result = PricingPlans::Result.blocked("blocked!", limit_key: :projects, billable: create_organization)
    ctrl.send(:handle_pricing_plans_limit_blocked, result)
    # Default config picks a default plan name; accept any string for plan
    assert_equal :forbidden, ctrl._rendered[0]
    assert_nil ctrl._rendered[1]
    assert_equal "blocked!", ctrl._rendered[2][:error]
    assert_equal :projects, ctrl._rendered[2][:limit]
    assert_kind_of String, ctrl._rendered[2][:plan]
  end
end
