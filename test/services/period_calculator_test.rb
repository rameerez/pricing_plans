# frozen_string_literal: true

require "test_helper"

class PeriodCalculatorTest < ActiveSupport::TestCase
  def test_billing_cycle_with_active_subscription
    org = create_organization(
      pay_subscription: { 
        active: true,
        processor_plan: "price_pro_123"
      }
    )
    
    # Mock subscription with period dates
    subscription = org.subscription
    subscription.define_singleton_method(:current_period_start) { Time.parse("2025-01-01 00:00:00 UTC") }
    subscription.define_singleton_method(:current_period_end) { Time.parse("2025-02-01 00:00:00 UTC") }
    
    period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
    
    assert_equal Time.parse("2025-01-01 00:00:00 UTC"), period_start
    assert_equal Time.parse("2025-02-01 00:00:00 UTC"), period_end
  end

  def test_billing_cycle_fallback_to_calendar_month
    org = create_organization  # No subscription
    
    travel_to_time(Time.parse("2025-01-15 12:00:00 UTC")) do
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
      
      assert_equal Time.parse("2025-01-01 00:00:00 UTC").in_time_zone, period_start
      assert_equal Time.parse("2025-01-31 23:59:59.999999999 UTC").in_time_zone, period_end
    end
  end

  def test_calendar_month_period
    # Override period cycle for this test
    PricingPlans.configuration.period_cycle = :calendar_month
    
    org = create_organization
    
    travel_to_time(Time.parse("2025-03-15 12:00:00 UTC")) do
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
      
      assert_equal Time.parse("2025-03-01 00:00:00 UTC").in_time_zone, period_start
      assert_equal Time.parse("2025-03-31 23:59:59.999999999 UTC").in_time_zone, period_end
    end
  end

  def test_calendar_week_period
    PricingPlans.configuration.period_cycle = :calendar_week
    
    org = create_organization
    
    travel_to_time(Time.parse("2025-01-15 12:00:00 UTC")) do  # Wednesday
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
      
      # Should span from Monday to Sunday
      assert_equal 1, period_start.wday  # Monday
      assert_equal 0, period_end.wday    # Sunday (end of week)
    end
  end

  def test_calendar_day_period
    PricingPlans.configuration.period_cycle = :calendar_day
    
    org = create_organization
    
    travel_to_time(Time.parse("2025-01-15 12:30:45 UTC")) do
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
      
      assert_equal Time.parse("2025-01-15 00:00:00 UTC").in_time_zone, period_start
      assert_equal Time.parse("2025-01-15 23:59:59.999999999 UTC").in_time_zone, period_end
    end
  end

  def test_custom_callable_period
    custom_period = ->(billable) do
      [Time.parse("2025-01-01 00:00:00 UTC"), Time.parse("2025-01-07 23:59:59 UTC")]
    end
    
    PricingPlans.configuration.period_cycle = custom_period
    
    org = create_organization
    period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
    
    assert_equal Time.parse("2025-01-01 00:00:00 UTC"), period_start
    assert_equal Time.parse("2025-01-07 23:59:59 UTC"), period_end
  end

  def test_custom_callable_validation_invalid_return_type
    invalid_period = ->(billable) { "not an array" }
    
    PricingPlans.configuration.period_cycle = invalid_period
    
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans::PeriodCalculator.window_for(create_organization, :projects)
    end
    
    assert_match(/must return \[start_time, end_time\]/, error.message)
  end

  def test_custom_callable_validation_invalid_time_objects
    invalid_period = ->(billable) { ["not a time", "also not a time"] }
    
    PricingPlans.configuration.period_cycle = invalid_period
    
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans::PeriodCalculator.window_for(create_organization, :projects)
    end
    
    assert_match(/must respond to :to_time/, error.message)
  end

  def test_custom_callable_validation_end_before_start
    invalid_period = ->(billable) do
      [Time.parse("2025-01-02 00:00:00 UTC"), Time.parse("2025-01-01 00:00:00 UTC")]
    end
    
    PricingPlans.configuration.period_cycle = invalid_period
    
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans::PeriodCalculator.window_for(create_organization, :projects)
    end
    
    assert_match(/end_time must be after start_time/, error.message)
  end

  def test_duration_period_with_active_support_duration
    PricingPlans.configuration.period_cycle = 2.weeks
    
    org = create_organization
    
    travel_to_time(Time.parse("2025-01-15 12:00:00 UTC")) do
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
      
      assert_equal Time.parse("2025-01-15 00:00:00 UTC").in_time_zone, period_start
      assert_equal Time.parse("2025-01-29 00:00:00 UTC").in_time_zone, period_end
    end
  end

  def test_per_limit_period_override
    # Global config is billing_cycle, but this limit uses calendar_month
    PricingPlans.reset_configuration!
    
    PricingPlans.configure do |config|
      config.billable_class = "Organization"
      config.default_plan = :free
      config.period_cycle = :billing_cycle  # Global default
      
      plan :free do
        price 0
        limits :custom_models, to: 3, per: :calendar_month  # Override for this limit
      end
    end

    org = create_organization
    
    travel_to_time(Time.parse("2025-01-15 12:00:00 UTC")) do
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :custom_models)
      
      # Should use calendar_month despite global billing_cycle setting
      assert_equal Time.parse("2025-01-01 00:00:00 UTC").in_time_zone, period_start
      assert_equal Time.parse("2025-01-31 23:59:59.999999999 UTC").in_time_zone, period_end
    end
  end

  def test_billing_cycle_with_subscription_created_date_fallback
    org = create_organization(
      pay_subscription: { 
        active: true,
        processor_plan: "price_pro_123"
      }
    )
    
    # Mock subscription without period start/end but with created_at
    subscription = org.subscription
    subscription.define_singleton_method(:current_period_start) { nil }
    subscription.define_singleton_method(:current_period_end) { nil }
    subscription.define_singleton_method(:created_at) { Time.parse("2025-01-01 00:00:00 UTC") }
    
    travel_to_time(Time.parse("2025-01-15 12:00:00 UTC")) do
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
      
      # Should calculate monthly period from subscription creation
      assert_equal Time.parse("2025-01-01 00:00:00 UTC"), period_start
      assert_equal Time.parse("2025-02-01 00:00:00 UTC"), period_end
    end
  end

  def test_billing_cycle_monthly_calculation_across_boundaries
    org = create_organization(
      pay_subscription: { 
        active: true,
        processor_plan: "price_pro_123"
      }
    )
    
    subscription = org.subscription
    subscription.define_singleton_method(:current_period_start) { nil }
    subscription.define_singleton_method(:current_period_end) { nil }
    subscription.define_singleton_method(:created_at) { Time.parse("2024-11-15 00:00:00 UTC") }
    
    travel_to_time(Time.parse("2025-01-20 12:00:00 UTC")) do
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
      
      # Should be in the current billing period
      assert_equal Time.parse("2025-01-15 00:00:00 UTC"), period_start
      assert_equal Time.parse("2025-02-15 00:00:00 UTC"), period_end
    end
  end

  def test_period_calculation_edge_case_leap_year
    # Test February in a leap year
    travel_to_time(Time.parse("2024-02-15 12:00:00 UTC")) do  # 2024 is a leap year
      org = create_organization
      PricingPlans.configuration.period_cycle = :calendar_month
      
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
      
      assert_equal Time.parse("2024-02-01 00:00:00 UTC").in_time_zone, period_start
      assert_equal Time.parse("2024-02-29 23:59:59.999999999 UTC").in_time_zone, period_end
    end
  end

  def test_unknown_period_type_raises_error
    PricingPlans.configuration.period_cycle = :invalid_period_type
    
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans::PeriodCalculator.window_for(create_organization, :projects)
    end
    
    assert_match(/Unknown period type: invalid_period_type/, error.message)
  end

  def test_pay_gem_unavailable_fallback
    org = create_organization
    
    # Mock Pay as unavailable
    PricingPlans::PeriodCalculator.stub(:pay_available?, false) do
      period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
      
      # Should fall back to calendar month
      travel_to_time(Time.parse("2025-01-15 12:00:00 UTC")) do
        period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
        
        assert period_start.month == 1
        assert period_end.month == 1
      end
    end
  end

  def test_multiple_subscriptions_scenario
    org = create_organization
    
    # Mock multiple subscriptions with only one active
    inactive_sub = OpenStruct.new(active?: false, on_trial?: false, on_grace_period?: false)
    active_sub = OpenStruct.new(
      active?: true,
      on_trial?: false,
      on_grace_period?: false,
      current_period_start: Time.parse("2025-01-01 00:00:00 UTC"),
      current_period_end: Time.parse("2025-02-01 00:00:00 UTC")
    )
    
    org.define_singleton_method(:subscription) { nil }  # Primary subscription nil
    org.define_singleton_method(:subscriptions) { [inactive_sub, active_sub] }
    
    period_start, period_end = PricingPlans::PeriodCalculator.window_for(org, :projects)
    
    assert_equal Time.parse("2025-01-01 00:00:00 UTC"), period_start
    assert_equal Time.parse("2025-02-01 00:00:00 UTC"), period_end
  end

  private

  def travel_to_time(time)
    Time.stub(:current, time) do
      yield
    end
  end
end