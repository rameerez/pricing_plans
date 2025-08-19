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

    Report = Struct.new(:items, :message, keyword_init: true)

    class << self
      # Compute overage against a target plan for the given plan_owner.
      # Returns an array of OverageItem for limits that are over the target.
      # kind: :persistent or :per_period
      def report(plan_owner, target_plan)
        plan = target_plan.is_a?(PricingPlans::Plan) ? target_plan : Registry.plan(target_plan.to_sym)

        plan.limits.map do |limit_key, limit_config|
          next if limit_config[:to] == :unlimited

          usage = LimitChecker.current_usage_for(plan_owner, limit_key, limit_config)
          allowed = limit_config[:to]
          over_by = [usage - allowed.to_i, 0].max
          next if over_by <= 0

          OverageItem.new(
            limit_key: limit_key,
            kind: (limit_config[:per] ? :per_period : :persistent),
            current_usage: usage,
            allowed: allowed,
            overage: over_by,
            grace_active: GraceManager.grace_active?(plan_owner, limit_key),
            grace_ends_at: GraceManager.grace_ends_at(plan_owner, limit_key)
          )
        end.compact
      end

      # Returns a Report with items and a human message suitable for downgrade UX.
      def report_with_message(plan_owner, target_plan)
        items = report(plan_owner, target_plan)
        return Report.new(items: [], message: "No overages on target plan") if items.empty?

        parts = items.map do |i|
          "#{i.limit_key}: #{i.current_usage} > #{i.allowed} (reduce by #{i.overage})"
        end
        grace_info = items.select(&:grace_active).map do |i|
          ends = i.grace_ends_at&.utc&.iso8601
          "#{i.limit_key} grace ends at #{ends}"
        end

        msg = if PricingPlans.configuration&.message_builder
          begin
            built = PricingPlans.configuration.message_builder.call(
              context: :overage_report,
              items: items
            )
            built if built
          rescue StandardError
            nil
          end
        end
        msg ||= "Over target plan on: #{parts.join(', ')}. "
        msg += "Grace active — #{grace_info.join(', ')}." unless grace_info.empty?

        Report.new(items: items, message: msg)
      end

    end
  end
end
