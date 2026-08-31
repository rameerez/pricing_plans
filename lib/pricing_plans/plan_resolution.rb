# frozen_string_literal: true

module PricingPlans
  class PlanResolution < Struct.new(:plan, :source, :assignment, :subscription, keyword_init: true)
    SOURCES = [:assignment, :subscription, :default].freeze

    def initialize(**attributes)
      super

      unless SOURCES.include?(source)
        raise ArgumentError, "Invalid source: #{source.inspect}. Must be one of: #{SOURCES.inspect}"
      end

      freeze
    end

    def assignment?
      source == :assignment
    end

    def pricing_plan_overridden?
      assignment?
    end

    def subscription?
      source == :subscription
    end

    def default?
      source == :default
    end

    def plan_key
      plan&.key
    end

    def assignment_source
      assignment&.source
    end

    def pricing_plan_override
      assignment
    end

    def pricing_plan_override_source
      assignment_source
    end

    # Extends Struct#to_h with derived fields.
    # Note: this preserves the raw plan / assignment / subscription objects.
    def to_h
      super.merge(
        plan_key: plan_key,
        assignment_source: assignment_source,
        pricing_plan_overridden: pricing_plan_overridden?,
        pricing_plan_override: pricing_plan_override,
        pricing_plan_override_source: pricing_plan_override_source
      )
    end
  end
end
