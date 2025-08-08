# frozen_string_literal: true

module PricingPlans
  class OverageReporter
    OverageItem = Struct.new(
      :limit_key,
      :kind,
      :current_usage,
      :allowed,
      :overage,
      :grace_active,
      :grace_ends_at,
      keyword_init: true
    )

    class << self
      # Compute overage against a target plan for the given billable.
      # Returns an array of OverageItem for limits that are over the target.
      # kind: :persistent or :per_period
      def report(billable, target_plan)
        plan = target_plan.is_a?(PricingPlans::Plan) ? target_plan : Registry.plan(target_plan.to_sym)

        plan.limits.map do |limit_key, limit_config|
          next if limit_config[:to] == :unlimited

          usage = LimitChecker.current_usage_for(billable, limit_key, limit_config)
          allowed = limit_config[:to]
          over_by = [usage - allowed.to_i, 0].max
          next if over_by <= 0

          OverageItem.new(
            limit_key: limit_key,
            kind: (limit_config[:per] ? :per_period : :persistent),
            current_usage: usage,
            allowed: allowed,
            overage: over_by,
            grace_active: GraceManager.grace_active?(billable, limit_key),
            grace_ends_at: GraceManager.grace_ends_at(billable, limit_key)
          )
        end.compact
      end
    end
  end
end
