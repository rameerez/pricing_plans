# frozen_string_literal: true

module PricingPlans
  module Limitable
    extend ActiveSupport::Concern

    included do
      # Track all limited_by configurations for this model
      class_attribute :pricing_plans_limits, default: {}

      # Callbacks for automatic tracking
      after_create :increment_per_period_counters
      after_destroy :decrement_persistent_counters
      # Add billable-centric convenience methods to instances of the billable class
      # when possible. These are no-ops if the model isn't the billable itself.
      define_method :within_plan_limits? do |limit_key, by: 1|
        LimitChecker.within_limit?(self, limit_key, by: by)
      end

      define_method :plan_limit_remaining do |limit_key|
        LimitChecker.remaining(self, limit_key)
      end

      define_method :plan_limit_percent_used do |limit_key|
        LimitChecker.percent_used(self, limit_key)
      end

      define_method :current_pricing_plan do
        PlanResolver.effective_plan_for(self)
      end

      define_singleton_method :assign_pricing_plan! do |billable, plan_key, source: "manual"|
        Assignment.assign_plan_to(billable, plan_key, source: source)
      end
    end

    class_methods do
      # New ergonomic macro: limited_by_pricing_plans
      # - Auto-includes this concern if not already included
      # - Infers limit_key from model's collection/table name when not provided
      # - Infers billable association from configured billable_class (or common conventions)
      # - Accepts `per:` to declare per-period allowances
      def limited_by_pricing_plans(limit_key, billable:, per: nil, error_after_limit: nil, count_scope: nil)
        limit_key = limit_key.to_sym
        billable_method = billable.to_sym

        # Store the configuration
        self.pricing_plans_limits = pricing_plans_limits.merge(
          limit_key => {
            billable_method: billable_method,
            per: per,
            error_after_limit: error_after_limit,
            count_scope: count_scope
          }
        )

        # Register counter only for persistent caps
        unless per
          source_proc = count_scope
          PricingPlans::LimitableRegistry.register_counter(limit_key) do |billable_instance|
            # Base relation for this limited model and billable
            base_relation = relation_for_billable(billable_instance, billable_method)

            # Prefer plan-level count_scope if present; fallback to model-provided one
            scope_cfg = begin
              plan = PlanResolver.effective_plan_for(billable_instance)
              cfg = plan&.limit_for(limit_key)
              cfg && cfg[:count_scope]
            end
            scope_cfg ||= source_proc if source_proc

            relation = apply_count_scope(base_relation, scope_cfg, billable_instance)
            relation.respond_to?(:count) ? relation.count : base_relation.count
          end
        end

        # Add validation to prevent creation when over limit
        validate_limit_on_create(limit_key, billable_method, per, error_after_limit)
      end

      def count_for_billable(billable_instance, billable_method)
        relation_for_billable(billable_instance, billable_method).count
      end

      def relation_for_billable(billable_instance, billable_method)
        joins_condition = if billable_method == :self
          { id: billable_instance.id }
        else
          { billable_method => billable_instance }
        end
        where(joins_condition)
      end

      # Apply a flexible count_scope to an ActiveRecord::Relation.
      # Accepts Proc/Lambda, Symbol (scope name), Hash (where), or Array of these.
      def apply_count_scope(relation, scope_cfg, billable_instance)
        return relation unless scope_cfg

        case scope_cfg
        when Array
          scope_cfg.reduce(relation) { |rel, cfg| apply_count_scope(rel, cfg, billable_instance) }
        when Proc
          # Support arity variants: (rel) or (rel, billable)
          case scope_cfg.arity
          when 1 then scope_cfg.call(relation)
          when 2 then scope_cfg.call(relation, billable_instance)
          else
            relation.instance_exec(&scope_cfg)
          end
        when Symbol
          if relation.respond_to?(scope_cfg)
            relation.public_send(scope_cfg)
          else
            relation
          end
        when Hash
          relation.where(scope_cfg)
        else
          relation
        end
      end

      private

      def validate_limit_on_create(limit_key, billable_method, per, error_after_limit)
        method_name = :"check_limit_on_create_#{limit_key}"

        # Only define the method if it doesn't already exist
        unless method_defined?(method_name)
          validate method_name, on: :create

          define_method method_name do
            billable_instance = (billable_method == :self) ? self : send(billable_method)
            return unless billable_instance

            # Skip validation if the billable doesn't have limits configured
            plan = PlanResolver.effective_plan_for(billable_instance)
            limit_config = plan&.limit_for(limit_key)
            return unless limit_config
            return if limit_config[:to] == :unlimited

            # For persistent caps, check if we'd exceed the limit
            if per.nil?
              current_count = self.class.count_for_billable(billable_instance, billable_method)
              if current_count >= limit_config[:to]
                # Check grace/block policy
                case limit_config[:after_limit]
                when :just_warn
                  # Allow creation with warning
                  return
                when :block_usage, :grace_then_block
                  if limit_config[:after_limit] == :block_usage || GraceManager.should_block?(billable_instance, limit_key)
                    message = error_after_limit || "Cannot create #{self.class.name.downcase}: #{limit_key} limit exceeded"
                    errors.add(:base, message)
                  end
                end
              end
            else
              # For per-period limits, check usage in current period
              current_usage = LimitChecker.current_usage_for(billable_instance, limit_key, limit_config)
              if current_usage >= limit_config[:to]
                case limit_config[:after_limit]
                when :just_warn
                  return
                when :block_usage, :grace_then_block
                  if limit_config[:after_limit] == :block_usage || GraceManager.should_block?(billable_instance, limit_key)
                    message = error_after_limit || "Cannot create #{self.class.name.downcase}: #{limit_key} limit exceeded for this period"
                    errors.add(:base, message)
                  end
                end
              end
            end
          end
        end
      end
    end

    private

    def increment_per_period_counters
      self.class.pricing_plans_limits.each do |limit_key, config|
        next unless config[:per] # Only per-period limits

        billable_instance = (config[:billable_method] == :self) ? self : send(config[:billable_method])

        next unless billable_instance

        period_start, period_end = PeriodCalculator.window_for(billable_instance, limit_key)

        # Use upsert for better performance and concurrency handling
        usage = Usage.find_or_initialize_by(
          billable: billable_instance,
          limit_key: limit_key.to_s,
          period_start: period_start,
          period_end: period_end
        )

        if usage.new_record?
          usage.used = 1
          usage.last_used_at = Time.current

          begin
            usage.save!
          rescue ActiveRecord::RecordNotUnique
            # Handle race condition - record was created by another process
            usage = Usage.find_by(
              billable: billable_instance,
              limit_key: limit_key.to_s,
              period_start: period_start,
              period_end: period_end
            )
            usage&.increment!
          end
        else
          usage.increment!
        end
      end
    end

    def decrement_persistent_counters
      # For persistent caps, we don't need to do anything on destroy
      # since the counter is computed live from the database
      # The record being destroyed will automatically reduce the count
    end
  end
end
