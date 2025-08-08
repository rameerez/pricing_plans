# frozen_string_literal: true

module PricingPlans
  # Mix-in for the configured billable class (e.g., Organization)
  # Provides readable, billable-centric helpers.
  module Billable
    def within_plan_limits?(limit_key, by: 1)
      LimitChecker.within_limit?(self, limit_key, by: by)
    end

    def plan_limit_remaining(limit_key)
      LimitChecker.remaining(self, limit_key)
    end

    # Short, English-y alias
    def remaining(limit_key)
      plan_limit_remaining(limit_key)
    end

    def plan_limit_percent_used(limit_key)
      LimitChecker.percent_used(self, limit_key)
    end

    # Short alias
    def percent_used(limit_key)
      plan_limit_percent_used(limit_key)
    end

    def current_pricing_plan
      PlanResolver.effective_plan_for(self)
    end

    def assign_pricing_plan!(plan_key, source: "manual")
      Assignment.assign_plan_to(self, plan_key, source: source)
    end

    def remove_pricing_plan!
      Assignment.remove_assignment_for(self)
    end
  end
end
