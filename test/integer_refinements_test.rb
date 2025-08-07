# frozen_string_literal: true

require "test_helper"

# Test class that uses refinement at the top level
class TestWithRefinement
  using PricingPlans::IntegerRefinements
  
  def self.test_max_method(number)
    number.max
  end
  
  def self.test_time_methods
    if 1.respond_to?(:days)
      # ActiveSupport is loaded, use its methods
      {
        one_day: 1.day,
        seven_days: 7.days,
        one_week: 1.week,
        two_weeks: 2.weeks
      }
    else
      # Use our fallback implementations
      {
        one_day: 1.day,
        seven_days: 7.days,
        one_week: 1.week,
        two_weeks: 2.weeks,
        one_month: 1.month,
        two_months: 2.months
      }
    end
  end
end

class IntegerRefinementsTest < ActiveSupport::TestCase
  def test_max_refinement
    assert_equal 5, TestWithRefinement.test_max_method(5)
    assert_equal 10, TestWithRefinement.test_max_method(10)
    assert_equal(-3, TestWithRefinement.test_max_method(-3))
  end

  def test_time_method_availability
    time_values = TestWithRefinement.test_time_methods
    
    if defined?(ActiveSupport)
      # ActiveSupport is loaded, so we get its duration objects
      assert_respond_to time_values[:one_day], :seconds
      assert_respond_to time_values[:seven_days], :seconds
      assert_respond_to time_values[:one_week], :seconds
      assert_respond_to time_values[:two_weeks], :seconds
    else
      # Our fallback implementations return raw seconds
      assert_equal 86400, time_values[:one_day]
      assert_equal 604800, time_values[:seven_days] # 7 * 86400
      assert_equal 604800, time_values[:one_week]
      assert_equal 1209600, time_values[:two_weeks] # 14 * 86400
      assert_equal 2592000, time_values[:one_month] # 30 * 86400
      assert_equal 5184000, time_values[:two_months] # 60 * 86400
    end
  end

  def test_refinement_scoped_only_to_using_context
    # Outside the refinement scope, max method shouldn't be available on Integer
    # unless it's defined by something else
    if 5.respond_to?(:max)
      skip "Integer#max is available outside refinement scope (possibly from ActiveSupport or other gem)"
    else
      assert_raises(NoMethodError) do
        5.max
      end
    end
  end

  def test_refinement_provides_max_identity_function
    # Test that our refinement provides the .max method that returns self
    result_5 = TestWithRefinement.test_max_method(5)
    result_100 = TestWithRefinement.test_max_method(100)
    result_0 = TestWithRefinement.test_max_method(0)
    
    assert_equal 5, result_5
    assert_equal 100, result_100
    assert_equal 0, result_0
  end

  def test_refinement_module_exists
    assert defined?(PricingPlans::IntegerRefinements)
    assert PricingPlans::IntegerRefinements.is_a?(Module)
  end

  def test_refinement_provides_dsl_sugar
    # The refinement is used in Plan class to provide DSL sugar like `5.max`
    # This is tested via the TestWithRefinement class above
    limit_value = TestWithRefinement.test_max_method(42)
    assert_equal 42, limit_value
    
    # The refinement enables expressive DSL like `limits :projects, to: 5.max`
    # where 5.max is just syntactic sugar that returns 5
    assert_equal 5, TestWithRefinement.test_max_method(5)
  end
end