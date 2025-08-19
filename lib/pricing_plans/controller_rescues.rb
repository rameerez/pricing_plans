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
            if error.respond_to?(:plan_owner)
              plan_obj = PricingPlans::PlanResolver.effective_plan_for(error.plan_owner)
            elsif error.respond_to?(:plan_owner)
              plan_obj = PricingPlans::PlanResolver.effective_plan_for(error.plan_owner)
            else
              plan_obj = nil
            end
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

    # Centralized handler for plan limit blocks. Apps can override this method
    # in their own ApplicationController to customize redirects/flash.
    # Receives the PricingPlans::Result for the blocked check.
    def handle_pricing_plans_limit_blocked(result)
      message = result&.message || "Plan limit reached"
      redirect_target = (result&.metadata || {})[:redirect_to]

      if html_request?
        # Prefer explicit/derived redirect target if provided by the guard
        if redirect_target
          flash[:alert] = message if respond_to?(:flash)
          redirect_to(redirect_target, status: :see_other) if respond_to?(:redirect_to)
        elsif respond_to?(:pricing_path)
          flash[:alert] = message if respond_to?(:flash)
          redirect_to(pricing_path, status: :see_other) if respond_to?(:redirect_to)
        else
          flash.now[:alert] = message if respond_to?(:flash) && flash.respond_to?(:now)
          render(status: :forbidden, plain: message) if respond_to?(:render)
        end
      elsif json_request?
        payload = {
          error: message,
          limit: result&.limit_key,
          plan: begin
            plan_obj = PricingPlans::PlanResolver.effective_plan_for(result&.plan_owner)
            plan_obj&.name
          rescue StandardError
            nil
          end
        }.compact
        render(json: payload, status: :forbidden) if respond_to?(:render)
      else
        render(json: { error: message }, status: :forbidden) if respond_to?(:render)
        head :forbidden if respond_to?(:head)
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
