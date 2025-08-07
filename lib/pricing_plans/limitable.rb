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
    end

    class_methods do
      # New ergonomic macro: limited_by_pricing_plans
      # - Auto-includes this concern if not already included
      # - Infers limit_key from model's collection/table name when not provided
      # - Infers billable association from configured billable_class (or common conventions)
      # - Accepts `per:` to declare per-period allowances
      def limited_by_pricing_plans(limit_key = nil, billable: nil, per: nil)
        include PricingPlans::Limitable unless ancestors.include?(PricingPlans::Limitable)

        inferred_limit_key = (limit_key || inferred_limit_key_for_model).to_sym
        inferred_billable   = infer_billable_association(billable)

        limited_by(inferred_limit_key, billable: inferred_billable, per: per)
      end

      # Backing implementation used by both the classic and new macro
      def limited_by(limit_key, billable:, per: nil)
        limit_key = limit_key.to_sym
        billable_method = billable.to_sym

        # Store the configuration
        self.pricing_plans_limits = pricing_plans_limits.merge(
          limit_key => {
            billable_method: billable_method,
            per: per
          }
        )

        # Register counter with LimitChecker
        if per.nil?
          # Persistent cap - register live counting logic
          PricingPlans::LimitableRegistry.register_counter(limit_key) do |billable_instance|
            count_for_billable(billable_instance, billable_method)
          end
        end

        # Add validation to prevent creation when over limit
        validate_limit_on_create(limit_key, billable_method, per)
      end

      def count_for_billable(billable_instance, billable_method)
        # Count all non-destroyed records for this billable
        joins_condition = if billable_method == :self
          { id: billable_instance.id }
        else
          { billable_method => billable_instance }
        end

        where(joins_condition).count
      end

      private

      def inferred_limit_key_for_model
        # Prefer table_name (works for anonymous AR classes with explicit table_name)
        return table_name if respond_to?(:table_name) && table_name

        # Fallback to model_name.collection only if the class has a real name
        if respond_to?(:name) && name && respond_to?(:model_name) && model_name.respond_to?(:collection)
          return model_name.collection
        end

        raise PricingPlans::ConfigurationError, "Cannot infer limit key: provide one explicitly"
      end

      def infer_billable_association(explicit)
        return explicit.to_sym if explicit

        # Prefer configured billable_class association name if present
        begin
          billable_klass = PricingPlans::Registry.billable_class
        rescue StandardError
          billable_klass = nil
        end

        if billable_klass
          association_name = billable_klass.name.underscore.to_sym
          return association_name if reflect_on_association(association_name)
        end

        # Common conventions fallback
        %i[organization account user team company workspace tenant].each do |candidate|
          return candidate if reflect_on_association(candidate)
        end

        # If nothing found, assume the record limits itself
        :self
      end

      def validate_limit_on_create(limit_key, billable_method, per)
        method_name = :"check_limit_on_create_#{limit_key}"

        # Only define the method if it doesn't already exist
        unless method_defined?(method_name)
          validate method_name, on: :create

          define_method method_name do
            billable_instance = if billable_method == :self
              self
            else
              send(billable_method)
            end

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
                  if GraceManager.should_block?(billable_instance, limit_key)
                    errors.add(:base, "Cannot create #{self.class.name.downcase}: #{limit_key} limit exceeded")
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
                  if GraceManager.should_block?(billable_instance, limit_key)
                    errors.add(:base, "Cannot create #{self.class.name.downcase}: #{limit_key} limit exceeded for this period")
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

        billable_instance = if config[:billable_method] == :self
          self
        else
          send(config[:billable_method])
        end

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
