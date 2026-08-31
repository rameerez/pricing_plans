# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module PricingPlans
  module Generators
    # Adds the pricing_plans_feature_grants table to apps that installed
    # pricing_plans before per-owner feature grants existed (< 0.6.0).
    # Fresh installs get the table from the install generator and never
    # need this one.
    class GrantsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Add the pricing_plans_feature_grants table (upgrade from pricing_plans < 0.6.0)"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_file
        migration_template "create_pricing_plans_feature_grants.rb.erb",
          File.join(db_migrate_path, "create_pricing_plans_feature_grants.rb"),
          migration_version: migration_version
      end

      def display_post_install_message
        say "\n✅ Feature grants migration created.", :green
        say "Run 'rails db:migrate', then grant per-owner features with e.g. `owner.grant_feature!(:some_feature, note: \"comp\")`."
        say "Note: declarative grandfathering (`grandfather :feature, subscribed_before: ...` in a plan) needs no table at all."
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
