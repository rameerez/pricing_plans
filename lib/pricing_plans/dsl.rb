# frozen_string_literal: true

module PricingPlans
  module DSL
    # This module provides common DSL functionality that can be included
    # in other classes to provide a consistent interface
    
    # Period constants for easy reference
    PERIOD_OPTIONS = [
      :billing_cycle,
      :calendar_month,
      :calendar_week,
      :calendar_day,
      :month,
      :week,
      :day
    ].freeze
    
    private
    
    def validate_period_option(period)
      return true if period.respond_to?(:call) # Custom callable
      return true if PERIOD_OPTIONS.include?(period)
      
      # Allow ActiveSupport duration objects
      return true if period.respond_to?(:seconds)
      
      false
    end
    
    def normalize_period(period)
      case period
      when :month
        :calendar_month
      when :week
        :calendar_week  
      when :day
        :calendar_day
      else
        period
      end
    end
  end
end