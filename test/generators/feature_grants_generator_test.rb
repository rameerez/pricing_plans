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
