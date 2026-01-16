# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# SimpleCov must be loaded BEFORE any application code
# Configuration is auto-loaded from .simplecov file
require "simplecov"

require "pricing_plans"
require "minitest/autorun"
require "minitest/mock"
require "minitest/pride" if ENV["PRIDE"]
require "active_record"
require "active_support"
require "active_support/test_case"
require "active_support/time"
require "ostruct"

# Mock Pay for testing
module Pay
  # Mock Pay module to simulate its presence for testing
end

# Set up test database
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

# Load schema
ActiveRecord::Schema.define do
  create_table :pricing_plans_enforcement_states do |t|
    t.string :plan_owner_type, null: false
    t.bigint :plan_owner_id, null: false
    t.string :limit_key, null: false
    t.datetime :exceeded_at
    t.datetime :blocked_at
    t.decimal :last_warning_threshold, precision: 3, scale: 2
    t.datetime :last_warning_at
    t.json :data, default: {}

    t.timestamps
  end

  add_index :pricing_plans_enforcement_states,
            [:plan_owner_type, :plan_owner_id, :limit_key],
            unique: true,
            name: 'idx_pricing_plans_enforcement_unique'

  create_table :pricing_plans_usages do |t|
    t.string :plan_owner_type, null: false
    t.bigint :plan_owner_id, null: false
    t.string :limit_key, null: false
    t.datetime :period_start, null: false
    t.datetime :period_end, null: false
    t.bigint :used, default: 0, null: false
    t.datetime :last_used_at

    t.timestamps
  end

  add_index :pricing_plans_usages,
            [:plan_owner_type, :plan_owner_id, :limit_key, :period_start],
            unique: true,
            name: 'idx_pricing_plans_usages_unique'

  create_table :pricing_plans_assignments do |t|
    t.string :plan_owner_type, null: false
    t.bigint :plan_owner_id, null: false
    t.string :plan_key, null: false
    t.string :source, null: false, default: 'manual'

    t.timestamps
  end

  add_index :pricing_plans_assignments,
            [:plan_owner_type, :plan_owner_id],
            unique: true

  # Test models
  create_table :organizations do |t|
    t.string :name
    t.timestamps
  end

  create_table :projects do |t|
    t.string :name
    t.references :organization, null: false
    t.timestamps
  end

  create_table :custom_models do |t|
    t.string :name
    t.references :organization, null: false
    t.timestamps
  end
end

# Test models
class Organization < ActiveRecord::Base
  include PricingPlans::PlanOwner
  has_many :projects, dependent: :destroy
  has_many :custom_models, dependent: :destroy

  # Mock Pay methods for testing
  attr_accessor :pay_subscription, :pay_trial, :pay_grace_period

  def pay_enabled?
    true # Always enabled for testing
  end

  def subscribed?
    pay_subscription.present? && pay_subscription[:active]
  end

  def on_trial?
    pay_trial.present?
  end

  def on_grace_period?
    pay_grace_period.present?
  end

  def subscription
    return nil unless subscribed? || on_trial? || on_grace_period?

    OpenStruct.new(
      processor_plan: pay_subscription&.dig(:processor_plan),
      active?: subscribed?,
      on_trial?: on_trial?,
      on_grace_period?: on_grace_period?,
      current_period_start: 1.month.ago,
      current_period_end: 1.day.from_now,
      created_at: 2.months.ago
    )
  end
end

class Project < ActiveRecord::Base
  belongs_to :organization
  include PricingPlans::Limitable
  limited_by_pricing_plans :projects, plan_owner: :organization
end

class CustomModel < ActiveRecord::Base
  belongs_to :organization
  include PricingPlans::Limitable
  limited_by_pricing_plans :custom_models, plan_owner: :organization, per: :month
end

# Test configuration helper
module TestConfigurationHelper
  def setup_test_plans
    PricingPlans.reset_configuration!

    PricingPlans.configure do |config|
      config.default_plan = :free
      config.highlighted_plan = :pro
      config.period_cycle = :billing_cycle

      config.plan :free do
        name "Free"
        description "Basic plan"
        price 0
        bullets "Limited features"

        limits :projects, to: 1, after_limit: :block_usage
        limits :custom_models, to: 0, per: :month
        disallows :api_access
      end

      config.plan :pro do
        stripe_price "price_pro_123"
        name "Pro"
        bullets "Advanced features", "API access"

        allows :api_access
        limits :projects, to: 10
        limits :custom_models, to: 3, per: :month, after_limit: :grace_then_block, grace: 7.days
        includes_credits 1000
      end

      config.plan :enterprise do
        price_string "Contact us"
        name "Enterprise"
        allows :api_access
        unlimited :projects, :custom_models
      end
    end
  end
end

class ActiveSupport::TestCase
  include TestConfigurationHelper

  def setup
    super
    setup_test_plans

    # Re-register model counters after configuration reset
    Project.send(:limited_by_pricing_plans, :projects, plan_owner: :organization) if Project.respond_to?(:limited_by_pricing_plans)
    CustomModel.send(:limited_by_pricing_plans, :custom_models, plan_owner: :organization, per: :month) if CustomModel.respond_to?(:limited_by_pricing_plans)

    # Clean up between tests
    PricingPlans::EnforcementState.destroy_all
    PricingPlans::Usage.destroy_all
    PricingPlans::Assignment.destroy_all
    Organization.destroy_all
  end

  def create_organization(attrs = {})
    Organization.create!(name: "Test Org", **attrs)
  end

  def travel_to_time(time)
    Time.stub(:current, time) do
      yield
    end
  end

  def stub_usage_credits_available
    Object.const_set(:UsageCredits, Class.new) unless defined?(UsageCredits)

    registry = Class.new do
      def self.operations
        { api_calls: :api_calls }
      end
    end

    UsageCredits.define_singleton_method(:registry) { registry }
  end

  def unstub_usage_credits
    Object.send(:remove_const, :UsageCredits) if defined?(UsageCredits)
  end
end
