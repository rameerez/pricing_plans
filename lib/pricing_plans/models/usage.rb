# frozen_string_literal: true

module PricingPlans
  class Usage < ActiveRecord::Base
    self.table_name = "pricing_plans_usages"

    belongs_to :plan_owner, polymorphic: true

    validates :limit_key, presence: true
    validates :period_start, :period_end, presence: true
    validates :used, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :period_start, uniqueness: { scope: [:plan_owner_type, :plan_owner_id, :limit_key] }

    validate :period_end_after_start

    scope :current_period, ->(period_start, period_end) {
      where(period_start: period_start, period_end: period_end)
    }

    scope :for_limit, ->(limit_key) { where(limit_key: limit_key.to_s) }

    def increment!(amount = 1)
      increment(:used, amount)
      update!(last_used_at: Time.current)
    end

    def within_period?(timestamp = Time.current)
      timestamp >= period_start && timestamp < period_end
    end

    def remaining(limit_amount)
      return Float::INFINITY if limit_amount == :unlimited
      [0, limit_amount - used].max
    end

    def percent_used(limit_amount)
      return 0.0 if limit_amount == :unlimited || limit_amount.zero?
      [(used.to_f / limit_amount) * 100, 100.0].min
    end

    private

    def period_end_after_start
      return unless period_start && period_end

      if period_end <= period_start
        errors.add(:period_end, "must be after period_start")
      end
    end
  end
end
