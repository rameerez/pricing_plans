# frozen_string_literal: true

module PricingPlans
  # Stores has_many limited_by_pricing_plans declarations that could not be
  # resolved at declaration time (e.g., child class not loaded yet). Flushed
  # after registry configuration or on engine to_prepare.
  class AssociationLimitRegistry
    class << self
      def pending
        @pending ||= []
      end

      def register(plan_owner_class:, association_name:, options:)
        pending << { plan_owner_class: plan_owner_class, association_name: association_name, options: options }
      end

      def flush_pending!
        pending.delete_if do |entry|
          owner = entry[:plan_owner_class]
          assoc = owner.reflect_on_association(entry[:association_name])
          next false unless assoc

          begin
            child_klass = assoc.klass
            child_klass.include PricingPlans::Limitable unless child_klass.ancestors.include?(PricingPlans::Limitable)
            opts = entry[:options]
            limit_key = (opts[:limit_key] || entry[:association_name]).to_sym
            # Define sugar methods on the plan owner when the association resolves
            PricingPlans::PlanOwner.define_limit_sugar_methods(owner, limit_key)
            child_klass.limited_by_pricing_plans(
              limit_key,
              plan_owner: child_klass.reflections.values.find { |r| r.macro == :belongs_to && r.foreign_key.to_s == assoc.foreign_key.to_s }&.name || owner.name.underscore.to_sym,
              per: opts[:per],
              error_after_limit: opts[:error_after_limit],
              count_scope: opts[:count_scope]
            )
            true
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
