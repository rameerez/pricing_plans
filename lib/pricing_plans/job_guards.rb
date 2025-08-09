# frozen_string_literal: true

module PricingPlans
  # Lightweight ergonomics for background jobs and services
  module JobGuards
    module_function

    # Runs the given block only if within limit or when system override is allowed.
    # Returns the Result in all cases so callers can inspect state.
    # Usage:
    #   PricingPlans::JobGuards.with_plan_limit(:licenses, billable: org, by: 1, allow_system_override: true) do |result|
    #     # perform work; result.warning?/grace? can be surfaced
    #   end
    def with_plan_limit(limit_key, billable:, by: 1, allow_system_override: false)
      result = ControllerGuards.require_plan_limit!(limit_key, billable: billable, by: by, allow_system_override: allow_system_override)

      blocked_without_override = result.blocked? && !(allow_system_override && result.metadata && result.metadata[:system_override])
      return result if blocked_without_override

      yield(result) if block_given?
      result
    end
  end
end
