# frozen_string_literal: true

module PricingPlans
  # Mix-in for the configured billable class (e.g., Organization)
  # Provides readable, billable-centric helpers.
  module Billable
    def self.included(base)
      base.extend(ClassMethods)
      base.singleton_class.prepend HasManyInterceptor
    end

    module HasManyInterceptor
      def has_many(name, scope = nil, **options, &extension)
        limited_opts = options.delete(:limited_by_pricing_plans)
        reflection = super(name, scope, **options, &extension)

        if limited_opts
          config = limited_opts == true ? {} : limited_opts.dup
          limit_key = (config.delete(:limit_key) || name).to_sym
          per = config.delete(:per)
          error_after_limit = config.delete(:error_after_limit)

          begin
            assoc_reflection = reflect_on_association(name)
            child_klass = assoc_reflection.klass
            foreign_key = assoc_reflection.foreign_key.to_s

            # Find the child's belongs_to backref to this billable
            inferred_billable = child_klass.reflections.values.find { |r| r.macro == :belongs_to && r.foreign_key.to_s == foreign_key }&.name
            # If foreign_key doesn't match (e.g., child uses :organization), prefer association matching billable's semantic name
            billable_name_sym = self.name.underscore.to_sym
            inferred_billable ||= (child_klass.reflections.key?(billable_name_sym.to_s) ? billable_name_sym : nil)
            # Common conventions fallback
            inferred_billable ||= %i[organization account user team company workspace tenant].find { |cand| child_klass.reflections.key?(cand.to_s) }
            # Final fallback to underscored class name
            inferred_billable ||= billable_name_sym

            child_klass.include PricingPlans::Limitable unless child_klass.ancestors.include?(PricingPlans::Limitable)
            child_klass.limited_by_pricing_plans(limit_key, billable: inferred_billable, per: per, error_after_limit: error_after_limit)
          rescue StandardError
            # If child class cannot be resolved yet, register for later resolution
            PricingPlans::AssociationLimitRegistry.register(
              billable_class: self,
              association_name: name,
              options: { limit_key: limit_key, per: per, error_after_limit: error_after_limit }
            )
          end
        end

        reflection
      end
    end

    module ClassMethods
    end

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
