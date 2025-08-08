# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module PricingPlans
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Install PricingPlans migrations and initializer"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_file
        migration_template "create_pricing_plans_tables.rb.erb", File.join(db_migrate_path, "create_pricing_plans_tables.rb"), migration_version: migration_version
      end

      def create_initializer
        template "initializer.rb", "config/initializers/pricing_plans.rb"
      end

      def display_post_install_message
        say "\n✅ pricing_plans has been installed.", :green
        say "\nNext steps:"
        say "  1. Run 'rails db:migrate' to create the necessary tables."
        say "  2. Review and customize 'config/initializers/pricing_plans.rb'."
        say "  3. Assign plans to your billable model (e.g., User/Organization)."
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
