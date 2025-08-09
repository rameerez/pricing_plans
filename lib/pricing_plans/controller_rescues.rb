# frozen_string_literal: true

module PricingPlans
  # Default controller-level rescues for a great out-of-the-box DX.
  # Included automatically by the engine into ActionController::Base and ActionController::API.
  # Applications can override by defining their own rescue_from handlers.
  module ControllerRescues
    def self.included(base)
      # Install a default mapping for FeatureDenied → 403 with helpful messaging.
      if base.respond_to?(:rescue_from)
        base.rescue_from(PricingPlans::FeatureDenied) do |error|
          handle_pricing_plans_feature_denied(error)
        end
      end
    end

    private

    # Default behavior tries to respond appropriately for HTML and JSON.
    # - HTML/Turbo: set a flash alert with an idiomatic message and redirect to pricing if available; otherwise render 403 with flash.now
    # - JSON: 403 with structured error { error, feature, plan }
    # Apps can override by defining this method in their own ApplicationController.
    def handle_pricing_plans_feature_denied(error)
      if html_request?
        # Prefer redirect + flash for idiomatic Rails UX when we have a pricing_path
        if respond_to?(:pricing_path)
          flash[:alert] = error.message
          redirect_to(pricing_path, status: :see_other)
        else
          # No pricing route helper; render with 403 and show inline flash
          flash.now[:alert] = error.message if respond_to?(:flash) && flash.respond_to?(:now)
          respond_to?(:render) ? render(status: :forbidden, plain: error.message) : head(:forbidden)
        end
      elsif json_request?
        payload = {
          error: error.message,
          feature: (error.respond_to?(:feature_key) ? error.feature_key : nil),
          plan: begin
            plan_obj = PricingPlans::PlanResolver.effective_plan_for(error.billable) if error.respond_to?(:billable)
            plan_obj&.name
          rescue StandardError
            nil
          end
        }.compact
        render(json: payload, status: :forbidden)
      else
        # API or miscellaneous formats
        if respond_to?(:render)
            render(json: { error: error.message }, status: :forbidden)
        else
          head :forbidden if respond_to?(:head)
        end
      end
    end

    def html_request?
      return false unless respond_to?(:request)
      req = request
      req && req.respond_to?(:format) && req.format.respond_to?(:html?) && req.format.html?
    rescue StandardError
      false
    end

    def json_request?
      return false unless respond_to?(:request)
      req = request
      req && req.respond_to?(:format) && req.format.respond_to?(:json?) && req.format.json?
    rescue StandardError
      false
    end
  end
end
