# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require_relative "../../lib/generators/pricing_plans/grants/grants_generator"
require_relative "../../lib/generators/pricing_plans/install/install_generator"

module GeneratorTestRailsConstant
  RAILS_FRAMEWORK = ::Rails

  def restore_rails_constant
    Object.const_set(:Rails, RAILS_FRAMEWORK) unless Object.const_defined?(:Rails)
  end
end

class FeatureGrantsGeneratorTest < Rails::Generators::TestCase
  include GeneratorTestRailsConstant

  tests PricingPlans::Generators::GrantsGenerator
  destination File.expand_path("../../tmp/grants_generator", __dir__)
  setup :restore_rails_constant
  setup :prepare_destination

  def test_upgrade_generator_creates_a_complete_migration
    run_generator

    assert_migration "db/migrate/create_pricing_plans_feature_grants.rb" do |migration|
      assert_includes migration, "class CreatePricingPlansFeatureGrants < ActiveRecord::Migration["
      assert_includes migration, "t.references :plan_owner, polymorphic: true, null: false"
      assert_includes migration, "t.string :feature_key, null: false"
      assert_includes migration, "t.string :source, null: false"
      assert_includes migration, "t.datetime :expires_at"
      assert_includes migration, "t.send(json_column_type, :limits, default: {}, null: false)"
      assert_includes migration, "def json_column_type"
      assert_includes migration, "t.bigint :usage_count, default: 0, null: false"
      assert_includes migration, "t.datetime :revoked_at"
      assert_includes migration, "idx_pricing_plans_feature_grants_lookup"
    end
  end
end

class FeatureGrantsInstallGeneratorTest < Rails::Generators::TestCase
  include GeneratorTestRailsConstant

  tests PricingPlans::Generators::InstallGenerator
  destination File.expand_path("../../tmp/install_generator", __dir__)
  setup :restore_rails_constant
  setup :prepare_destination

  def test_fresh_install_includes_feature_grants_and_the_initializer
    run_generator

    assert_file "config/initializers/pricing_plans.rb"
    assert_migration "db/migrate/create_pricing_plans_tables.rb" do |migration|
      assert_includes migration, "create_table :pricing_plans_feature_grants"
      assert_includes migration, "idx_pricing_plans_feature_grants_lookup"
    end
  end
end

require_relative "../../lib/generators/pricing_plans/passes/passes_generator"

class FeaturePassesGeneratorTest < Rails::Generators::TestCase
  include GeneratorTestRailsConstant
  tests PricingPlans::Generators::PassesGenerator
  destination File.expand_path("../../tmp/passes_generator", __dir__)
  setup :restore_rails_constant
  setup :prepare_destination

  def test_upgrade_adds_columns_and_constraint_without_touching_existing_grants
    run_generator
    assert_migration "db/migrate/add_feature_pass_limits.rb" do |migration|
      assert_includes migration, ":limits, json_column_type, default: {}, null: false"
      assert_includes migration, "def json_column_type"
      refute_match(/^\s{5,}t\.|^\s{0,3}t\./, migration, "generated columns must be indented consistently")
      assert_includes migration, ":usage_limit, :bigint"
      assert_includes migration, ":usage_count, :bigint, default: 0, null: false"
      assert_includes migration, "add_check_constraint"
      refute_includes migration, "delete"
      refute_includes migration, "drop_table"
    end
  end
end
