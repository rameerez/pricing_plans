# frozen_string_literal: true

require "test_helper"

class DSLTest < ActiveSupport::TestCase
  include PricingPlans::DSL

  def test_period_options_constant_is_frozen
    assert PricingPlans::DSL::PERIOD_OPTIONS.frozen?
    assert_includes PricingPlans::DSL::PERIOD_OPTIONS, :billing_cycle
    assert_includes PricingPlans::DSL::PERIOD_OPTIONS, :calendar_month
    assert_includes PricingPlans::DSL::PERIOD_OPTIONS, :calendar_week
    assert_includes PricingPlans::DSL::PERIOD_OPTIONS, :calendar_day
  end

  def test_validate_period_option_with_valid_symbols
    assert validate_period_option(:billing_cycle)
    assert validate_period_option(:calendar_month)
    assert validate_period_option(:calendar_week)
    assert validate_period_option(:calendar_day)
    assert validate_period_option(:month)
    assert validate_period_option(:week)
    assert validate_period_option(:day)
  end

  def test_validate_period_option_with_callable
    assert validate_period_option(-> { "test" })
    assert validate_period_option(proc { "test" })
    
    callable_object = Object.new
    def callable_object.call; end
    assert validate_period_option(callable_object)
  end

  def test_validate_period_option_with_duration_objects
    assert validate_period_option(1.day)
    assert validate_period_option(7.days)
    assert validate_period_option(1.month)
  end

  def test_validate_period_option_with_invalid_values
    refute validate_period_option(:invalid_period)
    refute validate_period_option("string")
    refute validate_period_option(Object.new)
    
    # Note: Integer responds to :seconds due to ActiveSupport, so numbers are valid
  end

  def test_normalize_period_shortcuts
    assert_equal :calendar_month, normalize_period(:month)
    assert_equal :calendar_week, normalize_period(:week)
    assert_equal :calendar_day, normalize_period(:day)
  end

  def test_normalize_period_passes_through_other_values
    assert_equal :billing_cycle, normalize_period(:billing_cycle)
    assert_equal :calendar_month, normalize_period(:calendar_month)
    assert_equal "custom", normalize_period("custom")
    
    callable = -> { "test" }
    assert_equal callable, normalize_period(callable)
  end
end