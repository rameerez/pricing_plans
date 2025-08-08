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

    initializer "pricing_plans.action_view" do
      ActiveSupport.on_load(:action_view) do
        include PricingPlans::ViewHelpers
      end
    end

    # Add generator paths
    config.generators do |g|
      g.templates.unshift File.expand_path("../../generators", __dir__)
    end
  end
end
