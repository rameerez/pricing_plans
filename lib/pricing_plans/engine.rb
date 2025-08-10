# frozen_string_literal: true

module PricingPlans
  class Engine < ::Rails::Engine
    isolate_namespace PricingPlans

    initializer "pricing_plans.active_record" do
      ActiveSupport.on_load(:active_record) do
        # Make models available
        require "pricing_plans/models/enforcement_state"
        require "pricing_plans/models/usage"
        require "pricing_plans/models/assignment"
      end
    end

    initializer "pricing_plans.action_controller" do
      ActiveSupport.on_load(:action_controller) do
        # Include controller guards in ApplicationController
        include PricingPlans::ControllerGuards
        # Install a sensible default rescue for feature gating so apps get 403 by default.
        # Apps can override by defining their own rescue_from in their controllers.
        include PricingPlans::ControllerRescues if defined?(PricingPlans::ControllerRescues)
      end
    end

    # Support API-only apps (ActionController::API)
    initializer "pricing_plans.action_controller_api" do
      ActiveSupport.on_load(:action_controller_api) do
        include PricingPlans::ControllerGuards
        include PricingPlans::ControllerRescues if defined?(PricingPlans::ControllerRescues)
      end
    end

    initializer "pricing_plans.action_view" do
      ActiveSupport.on_load(:action_view) do
        include PricingPlans::ViewHelpers
      end
    end

    # Ensure the configured billable class (e.g., Organization) gains the
    # billable-centric helpers even if the model is not loaded during
    # configuration time. Runs on each code reload in dev.
    initializer "pricing_plans.billable_helpers" do
      ActiveSupport::Reloader.to_prepare do
        begin
          klass = PricingPlans::Registry.billable_class
          if klass && !klass.included_modules.include?(PricingPlans::Billable)
            klass.include(PricingPlans::Billable)
          end
        rescue StandardError
          # If the billable class isn't resolved yet, skip; next reload will try again.
        end
      end
    end

    # Add generator paths
    config.generators do |g|
      g.templates.unshift File.expand_path("../../generators", __dir__)
    end

    # Map FeatureDenied to HTTP 403 by default so unhandled exceptions don't become 500s.
    initializer "pricing_plans.rescue_responses" do |app|
      app.config.action_dispatch.rescue_responses.merge!(
        "PricingPlans::FeatureDenied" => :forbidden
      ) if app.config.respond_to?(:action_dispatch) && app.config.action_dispatch.respond_to?(:rescue_responses)
    end
  end
end
