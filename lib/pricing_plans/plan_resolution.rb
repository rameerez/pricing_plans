# frozen_string_literal: true

module PricingPlans
  class PlanResolution < Struct.new(:plan, :source, :assignment, :subscription, keyword_init: true)
    SOURCES = [:assignment, :subscription, :default].freeze

    def initialize(**attributes)
      super

      unless SOURCES.include?(source)
        raise ArgumentError, "Invalid source: #{source.inspect}. Must be one of: #{SOURCES.inspect}"
      end
    end

    def assignment?
      source == :assignment
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

    # Extends Struct#to_h with derived fields commonly useful in serialization.
    def to_h
      {
        plan: plan,
        plan_key: plan_key,
        source: source,
        assignment: assignment,
        assignment_source: assignment_source,
        subscription: subscription
      }
    end
  end
end
