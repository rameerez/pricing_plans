# frozen_string_literal: true

require "test_helper"

class UsageTest < ActiveSupport::TestCase
  def setup
    super  # This calls the test helper setup which configures plans
    @org = create_organization
    @period_start = Time.parse("2025-01-01 00:00:00 UTC")
    @period_end = Time.parse("2025-01-31 23:59:59 UTC")
  end

  def test_factory_creates_valid_usage
    usage = PricingPlans::Usage.create!(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end,
      used: 5
    )
    
    assert usage.valid?
    assert_equal @org, usage.billable
    assert_equal "custom_models", usage.limit_key
    assert_equal 5, usage.used
  end

  def test_validation_requires_limit_key
    usage = PricingPlans::Usage.new(
      billable: @org,
      period_start: @period_start,
      period_end: @period_end
    )
    
    refute usage.valid?
    assert usage.errors[:limit_key].any?
  end

  def test_validation_requires_period_start
    usage = PricingPlans::Usage.new(
      billable: @org,
      limit_key: "custom_models",
      period_end: @period_end
    )
    
    refute usage.valid?
    assert usage.errors[:period_start].any?
  end

  def test_validation_requires_period_end
    usage = PricingPlans::Usage.new(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start
    )
    
    refute usage.valid?
    assert usage.errors[:period_end].any?
  end

  def test_uniqueness_constraint
    PricingPlans::Usage.create!(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end,
      used: 1
    )
    
    duplicate = PricingPlans::Usage.new(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end,
      used: 2
    )
    
    refute duplicate.valid?
    assert duplicate.errors[:period_start].any?
  end

  def test_different_periods_allowed
    usage1 = PricingPlans::Usage.create!(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end,
      used: 1
    )
    
    next_month_start = Time.parse("2025-02-01 00:00:00 UTC")
    next_month_end = Time.parse("2025-02-28 23:59:59 UTC")
    
    usage2 = PricingPlans::Usage.create!(
      billable: @org,
      limit_key: "custom_models",
      period_start: next_month_start,
      period_end: next_month_end,
      used: 2
    )
    
    assert usage1.valid?
    assert usage2.valid?
  end

  def test_different_limit_keys_allowed
    usage1 = PricingPlans::Usage.create!(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end,
      used: 1
    )
    
    usage2 = PricingPlans::Usage.create!(
      billable: @org,
      limit_key: "api_calls",
      period_start: @period_start,
      period_end: @period_end,
      used: 100
    )
    
    assert usage1.valid?
    assert usage2.valid?
  end

  def test_different_billables_allowed
    org2 = create_organization
    
    usage1 = PricingPlans::Usage.create!(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end,
      used: 1
    )
    
    usage2 = PricingPlans::Usage.create!(
      billable: org2,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end,
      used: 2
    )
    
    assert usage1.valid?
    assert usage2.valid?
  end

  def test_used_defaults_to_zero
    usage = PricingPlans::Usage.create!(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end
    )
    
    assert_equal 0, usage.used
  end

  def test_polymorphic_billable_association
    usage = PricingPlans::Usage.create!(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end
    )
    
    assert_equal @org, usage.billable
    assert_equal "Organization", usage.billable_type
    assert_equal @org.id, usage.billable_id
  end

  def test_increment_method_increases_used
    usage = PricingPlans::Usage.create!(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end,
      used: 5
    )
    
    usage.increment!
    assert_equal 6, usage.used
    
    usage.increment!(3)
    assert_equal 9, usage.used
  end

  def test_last_used_at_timestamp
    usage = PricingPlans::Usage.create!(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end
    )
    
    travel_to(Time.parse("2025-01-15 10:30:00 UTC")) do
      usage.update!(last_used_at: Time.current, used: 1)
      assert_equal Time.parse("2025-01-15 10:30:00 UTC"), usage.last_used_at
    end
  end

  def test_find_or_create_usage_pattern
    # Test the common pattern used in the Limitable module
    usage = PricingPlans::Usage.find_or_initialize_by(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end
    )
    
    assert usage.new_record?
    
    usage.used = 1
    usage.last_used_at = Time.current
    usage.save!
    
    # Find existing record
    existing = PricingPlans::Usage.find_or_initialize_by(
      billable: @org,
      limit_key: "custom_models",
      period_start: @period_start,
      period_end: @period_end
    )
    
    refute existing.new_record?
    assert_equal 1, existing.used
  end
end