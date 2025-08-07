# frozen_string_literal: true

require "rails/generators"

module PricingPlans
  module Generators
    class PricingGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Generate pricing page views and CSS"

      def create_views
        template "pricing.html.erb", "app/views/pricing/index.html.erb"
        template "_plan_card.html.erb", "app/views/pricing/_plan_card.html.erb" 
        template "_usage_meter.html.erb", "app/views/shared/_usage_meter.html.erb"
        template "_limit_banner.html.erb", "app/views/shared/_limit_banner.html.erb"
      end

      def create_stylesheet
        template "pricing_plans.css", "app/assets/stylesheets/pricing_plans.css"
      end

      def create_controller
        template "pricing_controller.rb", "app/controllers/pricing_controller.rb"
      end

      def add_routes
        route 'resources :pricing, only: [:index]'
      end

      def show_readme
        say "\nPricing views and controller generated!"
        say "Add this to your application layout to include styles:"
        say "  <%= stylesheet_link_tag 'pricing_plans' %>"
        say "\nCustomize the generated views in app/views/pricing/"
      end
    end
  end
end