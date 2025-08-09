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
      end
    end

    # Support API-only apps (ActionController::API)
    initializer "pricing_plans.action_controller_api" do
      ActiveSupport.on_load(:action_controller_api) do
        include PricingPlans::ControllerGuards
      end
    end

    initializer "pricing_plans.action_view" do
      ActiveSupport.on_load(:action_view) do
        include PricingPlans::ViewHelpers
        # Make engine views available for drop-in partials
        append_view_path File.expand_path("../../app/views", __dir__) if respond_to?(:append_view_path)
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
  end
end
