# frozen_string_literal: true

require "test_helper"
require "active_support/testing/time_helpers"

# Tests for automatic callback firing when models are created
# This ensures callbacks fire without requiring explicit controller guard calls
class AutomaticCallbacksTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  def setup
    super
    @emitted_events = []
  end

  def teardown
    super
    travel_back
  end

  # ==========================================================================
  # Core automatic callback tests
  # ==========================================================================

  def test_on_warning_fires_automatically_when_model_creation_crosses_threshold
    setup_plans_with_warning_thresholds

    org = create_organization
    org.assign_pricing_plan!(:pro_with_warnings)

    # Track emitted events via callback configuration
    track_events_via_callbacks!(:projects)

    # Create 7 projects (70% of 10 = crossing the 0.6 threshold)
    7.times { |i| org.projects.create!(name: "Project #{i + 1}") }

    # Warning should have fired at 60% threshold (when 6th project created)
    warning_events = @emitted_events.select { |e| e[:type] == :warning && e[:key] == :projects }
    assert warning_events.any?, "Expected on_warning to fire when crossing 60% threshold"
    assert_equal 0.6, warning_events.first[:threshold], "Expected 0.6 threshold"
  end

  def test_on_warning_fires_at_each_threshold_crossed
    setup_plans_with_warning_thresholds

    org = create_organization
    org.assign_pricing_plan!(:pro_with_warnings)

    track_events_via_callbacks!(:projects)

    # Create 10 projects one by one, should cross 0.6, 0.8, and 0.95 thresholds
    10.times { |i| org.projects.create!(name: "Project #{i + 1}") }

    warning_events = @emitted_events.select { |e| e[:type] == :warning && e[:key] == :projects }
    thresholds_fired = warning_events.map { |e| e[:threshold] }.uniq.sort

    # Should have fired at 0.6 (60%) and 0.8 (80%)
    assert_includes thresholds_fired, 0.6, "Expected warning at 60%"
    assert_includes thresholds_fired, 0.8, "Expected warning at 80%"
  end

  def test_on_grace_start_fires_automatically_when_limit_exceeded
    setup_plans_with_grace

    org = create_organization
    org.assign_pricing_plan!(:pro_with_grace)

    track_events_via_callbacks!(:projects)

    # Pro with grace allows 5 projects, then grace period starts
    # Create 6 projects to exceed the limit (5 + 1 over)
    6.times do |i|
      begin
        org.projects.create!(name: "Project #{i + 1}")
      rescue ActiveRecord::RecordInvalid
        # Expected for 6th if blocked
      end
    end

    grace_events = @emitted_events.select { |e| e[:type] == :grace_start && e[:key] == :projects }
    assert grace_events.any?, "Expected on_grace_start to fire when exceeding limit"
  end

  def test_on_block_fires_automatically_when_grace_expires
    setup_plans_with_grace

    org = create_organization
    org.assign_pricing_plan!(:pro_with_grace)

    track_events_via_callbacks!(:projects)

    travel_to Time.parse("2025-01-01 12:00:00 UTC") do
      # Exceed limit to start grace
      6.times do |i|
        begin
          org.projects.create!(name: "Project #{i + 1}")
        rescue ActiveRecord::RecordInvalid
          # Expected
        end
      end
    end

    # Travel past grace period (7 days)
    travel_to Time.parse("2025-01-09 12:00:00 UTC") do
      # Attempt another creation - this should trigger the block event
      begin
        org.projects.create!(name: "Project 7")
      rescue ActiveRecord::RecordInvalid
        # Expected to fail
      end

      block_events = @emitted_events.select { |e| e[:type] == :block && e[:key] == :projects }
      assert block_events.any?, "Expected on_block to fire when grace period expires"
    end
  end

  # ==========================================================================
  # Error isolation tests - callbacks should NEVER break the main operation
  # ==========================================================================

  def test_callback_error_does_not_prevent_model_creation
    setup_plans_with_warning_thresholds

    org = create_organization
    org.assign_pricing_plan!(:pro_with_warnings)

    # Setup a callback that raises an error
    PricingPlans.configuration.on_warning(:projects) do |_plan_owner, _threshold|
      raise "Intentional callback error!"
    end

    # Creating a model should still succeed even if callback crashes
    assert_nothing_raised do
      7.times { |i| org.projects.create!(name: "Project #{i + 1}") }
    end

    # Verify models were created
    assert_equal 7, org.projects.count
  end

  def test_callback_exception_is_isolated_not_propagated
    setup_plans_with_warning_thresholds

    org = create_organization
    org.assign_pricing_plan!(:pro_with_warnings)

    # Setup callback that raises
    PricingPlans.configuration.on_warning(:projects) do |_plan_owner, _threshold|
      raise StandardError, "Simulated failure"
    end

    # Should not raise - error should be caught and logged
    result = nil
    assert_nothing_raised do
      result = org.projects.create!(name: "Project 1")
    end

    assert result.persisted?, "Model should be persisted despite callback error"
  end

  def test_callbacks_do_not_fire_on_transaction_rollback
    setup_plans_with_warning_thresholds

    org = create_organization
    org.assign_pricing_plan!(:pro_with_warnings)

    callback_fired = false

    PricingPlans.configuration.on_warning(:projects) do |_plan_owner, _limit_key, _threshold|
      callback_fired = true
    end

    # Create enough projects to cross threshold, but rollback the transaction
    ActiveRecord::Base.transaction do
      6.times { |i| org.projects.create!(name: "Project #{i + 1}") }
      raise ActiveRecord::Rollback
    end

    # Verify the projects were rolled back
    assert_equal 0, org.projects.count, "Projects should have been rolled back"

    # After rollback, callback should NOT have fired (because we use after_commit)
    # Note: This test verifies the after_commit behavior - callbacks only fire
    # after successful transaction commit, not on rollback
    refute callback_fired, "Callback should not fire when transaction is rolled back"
  end

  # ==========================================================================
  # Per-period limit callback tests
  # ==========================================================================

  def test_on_warning_fires_for_per_period_limits
    setup_plans_with_per_period_warnings

    org = create_organization
    org.assign_pricing_plan!(:pro_with_period_warnings)

    track_events_via_callbacks!(:custom_models)

    travel_to Time.parse("2025-01-15 12:00:00 UTC") do
      # Create 8 custom models (80% of 10 per month)
      8.times { |i| org.custom_models.create!(name: "Model #{i + 1}") }
    end

    warning_events = @emitted_events.select { |e| e[:type] == :warning && e[:key] == :custom_models }
    assert warning_events.any?, "Expected on_warning to fire for per-period limit"
  end

  def test_per_period_warnings_reset_each_window
    setup_plans_with_per_period_warnings

    org = create_organization
    org.assign_pricing_plan!(:pro_with_period_warnings)

    track_events_via_callbacks!(:custom_models)

    # First month: trigger warning
    travel_to Time.parse("2025-01-15 12:00:00 UTC") do
      8.times { |i| org.custom_models.create!(name: "Jan Model #{i + 1}") }
    end

    first_month_warnings = @emitted_events.select { |e| e[:type] == :warning }.count

    # Next month: warnings should be able to fire again
    travel_to Time.parse("2025-02-15 12:00:00 UTC") do
      8.times { |i| org.custom_models.create!(name: "Feb Model #{i + 1}") }
    end

    total_warnings = @emitted_events.select { |e| e[:type] == :warning }.count
    assert total_warnings > first_month_warnings, "Expected warnings to reset and fire again in new period"
  end

  # ==========================================================================
  # Idempotency tests - same threshold should not fire twice in same window
  # ==========================================================================

  def test_same_warning_threshold_does_not_fire_twice
    setup_plans_with_warning_thresholds

    org = create_organization
    org.assign_pricing_plan!(:pro_with_warnings)

    track_events_via_callbacks!(:projects)

    # Create 6 projects (crosses 60%)
    6.times { |i| org.projects.create!(name: "Project #{i + 1}") }

    first_warning_count = @emitted_events.select { |e| e[:type] == :warning && e[:threshold] == 0.6 }.count

    # Delete one and recreate (still at 60%)
    org.projects.last.destroy
    org.projects.create!(name: "Recreated Project")

    second_warning_count = @emitted_events.select { |e| e[:type] == :warning && e[:threshold] == 0.6 }.count

    assert_equal first_warning_count, second_warning_count, "Same threshold should not fire again"
  end

  def test_grace_start_only_fires_once_per_window
    setup_plans_with_grace

    org = create_organization
    org.assign_pricing_plan!(:pro_with_grace)

    track_events_via_callbacks!(:projects)

    # Exceed limit multiple times
    travel_to Time.parse("2025-01-01 12:00:00 UTC") do
      10.times do |i|
        begin
          org.projects.create!(name: "Project #{i + 1}")
        rescue ActiveRecord::RecordInvalid
          # Some may fail, that's ok
        end
      end
    end

    grace_events = @emitted_events.select { |e| e[:type] == :grace_start && e[:key] == :projects }
    assert_equal 1, grace_events.count, "Grace start should only fire once"
  end

  # ==========================================================================
  # Wildcard callback tests - catch-all handlers for any limit
  # ==========================================================================

  def test_wildcard_on_warning_fires_for_any_limit
    setup_plans_with_warning_thresholds

    org = create_organization
    org.assign_pricing_plan!(:pro_with_warnings)

    wildcard_events = []

    # Register wildcard callback (no limit_key argument)
    PricingPlans.configuration.on_warning do |plan_owner, limit_key, threshold|
      wildcard_events << { plan_owner: plan_owner, limit_key: limit_key, threshold: threshold }
    end

    # Create projects to cross threshold
    6.times { |i| org.projects.create!(name: "Project #{i + 1}") }

    assert wildcard_events.any?, "Wildcard callback should fire"
    assert_equal :projects, wildcard_events.first[:limit_key], "Should receive limit_key"
    assert_equal 0.6, wildcard_events.first[:threshold], "Should receive threshold"
  end

  def test_wildcard_and_specific_callbacks_both_fire
    setup_plans_with_warning_thresholds

    org = create_organization
    org.assign_pricing_plan!(:pro_with_warnings)

    specific_fired = false
    wildcard_fired = false
    fire_order = []

    # Register specific callback
    PricingPlans.configuration.on_warning(:projects) do |_plan_owner, _limit_key, _threshold|
      specific_fired = true
      fire_order << :specific
    end

    # Register wildcard callback
    PricingPlans.configuration.on_warning do |_plan_owner, _limit_key, _threshold|
      wildcard_fired = true
      fire_order << :wildcard
    end

    6.times { |i| org.projects.create!(name: "Project #{i + 1}") }

    assert specific_fired, "Specific callback should fire"
    assert wildcard_fired, "Wildcard callback should also fire"
    assert_equal [:specific, :wildcard], fire_order, "Specific should fire before wildcard"
  end

  def test_wildcard_on_grace_start_fires
    setup_plans_with_grace

    org = create_organization
    org.assign_pricing_plan!(:pro_with_grace)

    wildcard_events = []

    PricingPlans.configuration.on_grace_start do |plan_owner, limit_key, grace_ends_at|
      wildcard_events << { plan_owner: plan_owner, limit_key: limit_key, grace_ends_at: grace_ends_at }
    end

    travel_to Time.parse("2025-01-01 12:00:00 UTC") do
      6.times do |i|
        begin
          org.projects.create!(name: "Project #{i + 1}")
        rescue ActiveRecord::RecordInvalid
          # Expected
        end
      end
    end

    assert wildcard_events.any?, "Wildcard grace_start callback should fire"
    assert_equal :projects, wildcard_events.first[:limit_key]
    assert_instance_of Time, wildcard_events.first[:grace_ends_at]
  end

  def test_wildcard_on_block_fires
    setup_plans_with_grace

    org = create_organization
    org.assign_pricing_plan!(:pro_with_grace)

    wildcard_events = []

    PricingPlans.configuration.on_block do |plan_owner, limit_key|
      wildcard_events << { plan_owner: plan_owner, limit_key: limit_key }
    end

    travel_to Time.parse("2025-01-01 12:00:00 UTC") do
      6.times do |i|
        begin
          org.projects.create!(name: "Project #{i + 1}")
        rescue ActiveRecord::RecordInvalid
          # Expected
        end
      end
    end

    # Travel past grace period
    travel_to Time.parse("2025-01-09 12:00:00 UTC") do
      begin
        org.projects.create!(name: "Project after grace")
      rescue ActiveRecord::RecordInvalid
        # Expected
      end
    end

    assert wildcard_events.any?, "Wildcard block callback should fire"
    assert_equal :projects, wildcard_events.first[:limit_key]
  end

  # ==========================================================================
  # Integration test: Full user scenario (License SaaS example)
  # ==========================================================================

  def test_license_saas_scenario_automatic_emails
    # This tests the exact scenario from the user request:
    # PRO users can have 100 licenses (we use :projects limit key with Project model)
    # Email at 80%, then at 95%

    setup_license_saas_plans

    org = create_organization
    org.assign_pricing_plan!(:pro)

    emails_sent = []

    # Configure callbacks to track "emails" (using :projects key since we use Project model)
    PricingPlans.configuration.on_warning(:projects) do |plan_owner, limit_key, threshold|
      emails_sent << { type: :warning, limit: limit_key, threshold: threshold, owner_id: plan_owner.id }
    end

    PricingPlans.configuration.on_grace_start(:projects) do |plan_owner, limit_key, grace_ends_at|
      emails_sent << { type: :grace_start, limit: limit_key, grace_ends_at: grace_ends_at, owner_id: plan_owner.id }
    end

    PricingPlans.configuration.on_block(:projects) do |plan_owner, limit_key|
      emails_sent << { type: :blocked, limit: limit_key, owner_id: plan_owner.id }
    end

    # Simulate creating licenses over time
    # Create 80 licenses (80% of 100)
    80.times { |i| create_license_for(org, "License #{i + 1}") }

    assert emails_sent.any? { |e| e[:type] == :warning && e[:threshold] == 0.8 },
           "Expected 80% warning email"

    # Create 15 more (95% of 100)
    15.times { |i| create_license_for(org, "License #{81 + i}") }

    assert emails_sent.any? { |e| e[:type] == :warning && e[:threshold] == 0.95 },
           "Expected 95% warning email"

    # Create more to exceed (over 100) - should trigger grace start
    10.times do |i|
      begin
        create_license_for(org, "License #{96 + i}")
      rescue ActiveRecord::RecordInvalid
        # May fail when limit is reached
      end
    end

    assert emails_sent.any? { |e| e[:type] == :grace_start },
           "Expected grace start email when limit exceeded"
  end

  # ==========================================================================
  # Test that callbacks work with the same signature as documented
  # ==========================================================================

  def test_on_warning_callback_receives_plan_owner_limit_key_and_threshold
    setup_plans_with_warning_thresholds

    org = create_organization
    org.assign_pricing_plan!(:pro_with_warnings)

    received_plan_owner = nil
    received_limit_key = nil
    received_threshold = nil

    PricingPlans.configuration.on_warning(:projects) do |plan_owner, limit_key, threshold|
      received_plan_owner = plan_owner
      received_limit_key = limit_key
      received_threshold = threshold
    end

    6.times { |i| org.projects.create!(name: "Project #{i + 1}") }

    assert_equal org, received_plan_owner, "Callback should receive plan_owner"
    assert_equal :projects, received_limit_key, "Callback should receive limit_key"
    assert_equal 0.6, received_threshold, "Callback should receive threshold"
  end

  def test_on_grace_start_callback_receives_plan_owner_limit_key_and_grace_ends_at
    setup_plans_with_grace

    org = create_organization
    org.assign_pricing_plan!(:pro_with_grace)

    received_plan_owner = nil
    received_limit_key = nil
    received_grace_ends_at = nil

    PricingPlans.configuration.on_grace_start(:projects) do |plan_owner, limit_key, grace_ends_at|
      received_plan_owner = plan_owner
      received_limit_key = limit_key
      received_grace_ends_at = grace_ends_at
    end

    travel_to Time.parse("2025-01-01 12:00:00 UTC") do
      6.times do |i|
        begin
          org.projects.create!(name: "Project #{i + 1}")
        rescue ActiveRecord::RecordInvalid
          # Expected
        end
      end
    end

    assert_equal org, received_plan_owner, "Callback should receive plan_owner"
    assert_equal :projects, received_limit_key, "Callback should receive limit_key"
    assert_instance_of Time, received_grace_ends_at, "Callback should receive grace_ends_at time"
  end

  def test_on_block_callback_receives_plan_owner_and_limit_key
    setup_plans_with_grace

    org = create_organization
    org.assign_pricing_plan!(:pro_with_grace)

    received_plan_owner = nil
    received_limit_key = nil

    PricingPlans.configuration.on_block(:projects) do |plan_owner, limit_key|
      received_plan_owner = plan_owner
      received_limit_key = limit_key
    end

    travel_to Time.parse("2025-01-01 12:00:00 UTC") do
      6.times do |i|
        begin
          org.projects.create!(name: "Project #{i + 1}")
        rescue ActiveRecord::RecordInvalid
          # Expected
        end
      end
    end

    # Travel past grace period
    travel_to Time.parse("2025-01-09 12:00:00 UTC") do
      begin
        org.projects.create!(name: "Project after grace")
      rescue ActiveRecord::RecordInvalid
        # Expected
      end
    end

    assert_equal org, received_plan_owner, "Callback should receive plan_owner"
    assert_equal :projects, received_limit_key, "Callback should receive limit_key"
  end

  private

  def track_events_via_callbacks!(limit_key)
    PricingPlans.configuration.on_warning(limit_key) do |plan_owner, key, threshold|
      @emitted_events << { type: :warning, key: key, plan_owner: plan_owner, threshold: threshold }
    end

    PricingPlans.configuration.on_grace_start(limit_key) do |plan_owner, key, grace_ends_at|
      @emitted_events << { type: :grace_start, key: key, plan_owner: plan_owner, grace_ends_at: grace_ends_at }
    end

    PricingPlans.configuration.on_block(limit_key) do |plan_owner, key|
      @emitted_events << { type: :block, key: key, plan_owner: plan_owner }
    end
  end

  def setup_plans_with_warning_thresholds
    PricingPlans.reset_configuration!
    PricingPlans::LimitableRegistry.clear!
    clear_model_limits!

    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        price 0
        limits :projects, to: 1
      end

      config.plan :pro_with_warnings do
        price 10
        limits :projects, to: 10, warn_at: [0.6, 0.8, 0.95], after_limit: :block_usage
      end
    end

    # Re-register counters
    Project.send(:limited_by_pricing_plans, :projects, plan_owner: :organization)
  end

  def setup_plans_with_grace
    PricingPlans.reset_configuration!
    PricingPlans::LimitableRegistry.clear!
    clear_model_limits!

    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        price 0
        limits :projects, to: 1
      end

      config.plan :pro_with_grace do
        price 10
        limits :projects, to: 5, after_limit: :grace_then_block, grace: 7.days, warn_at: [0.8]
      end
    end

    Project.send(:limited_by_pricing_plans, :projects, plan_owner: :organization)
  end

  def setup_plans_with_per_period_warnings
    PricingPlans.reset_configuration!
    PricingPlans::LimitableRegistry.clear!
    clear_model_limits!

    PricingPlans.configure do |config|
      config.default_plan = :free
      config.period_cycle = :calendar_month

      config.plan :free do
        price 0
        limits :custom_models, to: 0, per: :month
      end

      config.plan :pro_with_period_warnings do
        price 10
        limits :custom_models, to: 10, per: :month, warn_at: [0.6, 0.8, 0.95], after_limit: :grace_then_block, grace: 3.days
      end
    end

    CustomModel.send(:limited_by_pricing_plans, :custom_models, plan_owner: :organization, per: :month)
  end

  def setup_license_saas_plans
    PricingPlans.reset_configuration!
    PricingPlans::LimitableRegistry.clear!
    clear_model_limits!

    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        price 0
        limits :projects, to: 5
      end

      config.plan :pro do
        price 99
        limits :projects, to: 100, warn_at: [0.8, 0.95], after_limit: :grace_then_block, grace: 7.days
      end
    end

    # Use :projects limit key (matching the model's table)
    Project.send(:limited_by_pricing_plans, :projects, plan_owner: :organization)
  end

  def clear_model_limits!
    # Clear any registered limits on test models to avoid test pollution
    Project.pricing_plans_limits = {} if Project.respond_to?(:pricing_plans_limits=)
    CustomModel.pricing_plans_limits = {} if CustomModel.respond_to?(:pricing_plans_limits=)
  end

  def create_license_for(org, name)
    # Use Project as a stand-in for License in tests
    org.projects.create!(name: name)
  end
end
