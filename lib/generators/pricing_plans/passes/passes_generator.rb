# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module PricingPlans
  module Generators
    class PassesGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Add capacity limits and cumulative usage to existing feature grants"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_file
        migration_template "add_feature_pass_limits.rb.erb",
                           File.join(db_migrate_path, "add_feature_pass_limits.rb"),
                           migration_version: migration_version
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
