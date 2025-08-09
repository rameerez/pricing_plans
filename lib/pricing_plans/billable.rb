# frozen_string_literal: true

module PricingPlans
  # Mix-in for the configured billable class (e.g., Organization)
  # Provides readable, billable-centric helpers.
  module Billable
    def self.included(base)
      base.extend(ClassMethods)
      base.singleton_class.prepend HasManyInterceptor
    end

    # Define English-y sugar methods on the billable for a specific limit key.
    # Idempotent: skips if methods already exist.
    def self.define_limit_sugar_methods(billable_class, limit_key)
      key = limit_key.to_sym
      within_m = :"#{key}_within_plan_limits?"
      remaining_m = :"#{key}_remaining"
      percent_m = :"#{key}_percent_used"
      grace_active_m = :"#{key}_grace_active?"
      grace_ends_m = :"#{key}_grace_ends_at"
      blocked_m = :"#{key}_blocked?"

      unless billable_class.method_defined?(within_m)
        billable_class.define_method(within_m) do |by: 1|
          LimitChecker.within_limit?(self, key, by: by)
        end
      end

      unless billable_class.method_defined?(remaining_m)
        billable_class.define_method(remaining_m) do
          LimitChecker.remaining(self, key)
        end
      end

      unless billable_class.method_defined?(percent_m)
        billable_class.define_method(percent_m) do
          LimitChecker.percent_used(self, key)
        end
      end

      unless billable_class.method_defined?(grace_active_m)
        billable_class.define_method(grace_active_m) do
          GraceManager.grace_active?(self, key)
        end
      end

      unless billable_class.method_defined?(grace_ends_m)
        billable_class.define_method(grace_ends_m) do
          GraceManager.grace_ends_at(self, key)
        end
      end

      unless billable_class.method_defined?(blocked_m)
        billable_class.define_method(blocked_m) do
          GraceManager.should_block?(self, key)
        end
      end
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

          # Define English-y sugar methods on the billable immediately
          PricingPlans::Billable.define_limit_sugar_methods(self, limit_key)

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

    # Features
    def plan_allows?(feature_key)
      plan = current_pricing_plan
      plan&.allows_feature?(feature_key) || false
    end

    # Pay (Stripe) convenience wrappers (return false/nil if Pay not available)
    # Pay (Stripe) state — billing-facing, NOT used by our enforcement logic
    def pay_subscription_active?
      PaySupport.subscription_active_for?(self)
    end

    def pay_on_trial?
      sub = PaySupport.current_subscription_for(self)
      !!(sub && sub.respond_to?(:on_trial?) && sub.on_trial?)
    end

    def pay_on_grace_period?
      sub = PaySupport.current_subscription_for(self)
      !!(sub && sub.respond_to?(:on_grace_period?) && sub.on_grace_period?)
    end

    # Per-limit grace helpers managed by PricingPlans
    def grace_active_for?(limit_key)
      GraceManager.grace_active?(self, limit_key)
    end

    def grace_ends_at_for(limit_key)
      GraceManager.grace_ends_at(self, limit_key)
    end

    def grace_remaining_seconds_for(limit_key)
      ends_at = grace_ends_at_for(limit_key)
      return 0 unless ends_at
      [0, (ends_at - Time.current).to_i].max
    end

    def grace_remaining_days_for(limit_key)
      (grace_remaining_seconds_for(limit_key) / 86_400.0).ceil
    end

    def plan_blocked_for?(limit_key)
      GraceManager.should_block?(self, limit_key)
    end

    # Aggregate helpers across multiple limit keys
    def any_grace_active_for?(*limit_keys)
      limit_keys.flatten.any? { |k| GraceManager.grace_active?(self, k) }
    end

    def earliest_grace_ends_at_for(*limit_keys)
      times = limit_keys.flatten.map { |k| GraceManager.grace_ends_at(self, k) }.compact
      times.min
    end
  end
end
