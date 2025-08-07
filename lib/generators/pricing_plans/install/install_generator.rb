# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module PricingPlans
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      
      source_root File.expand_path("templates", __dir__)
      desc "Install PricingPlans migrations and initializer"

      def copy_initializer
        template "pricing_plans.rb", "config/initializers/pricing_plans.rb"
      end

      def create_migrations
        migration_template "create_pricing_plans_enforcement_states.rb", 
                          "db/migrate/create_pricing_plans_enforcement_states.rb"
                          
        migration_template "create_pricing_plans_usages.rb",
                          "db/migrate/create_pricing_plans_usages.rb"
                          
        migration_template "create_pricing_plans_assignments.rb",
                          "db/migrate/create_pricing_plans_assignments.rb"
      end

      def show_readme
        readme "README" if behavior == :invoke
      end

      private

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end
    end
  end
end