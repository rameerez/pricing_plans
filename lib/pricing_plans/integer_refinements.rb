# frozen_string_literal: true

module PricingPlans
  # Refinements for Integer to provide DSL sugar like `5.max`
  # This is scoped only to our DSL usage to avoid polluting the global namespace
  module IntegerRefinements
    refine Integer do
      def max
        self
      end
      
      # Additional convenience methods for time periods that read well in DSL
      alias_method :day, :day if method_defined?(:day)
      alias_method :days, :days if method_defined?(:days)
      alias_method :week, :week if method_defined?(:week)
      alias_method :weeks, :weeks if method_defined?(:weeks)
      alias_method :month, :month if method_defined?(:month) 
      alias_method :months, :months if method_defined?(:months)
      
      # If ActiveSupport isn't loaded, provide basic duration support
      unless method_defined?(:days)
        def days
          self * 86400 # seconds in a day
        end
        
        def day
          days
        end
        
        def weeks
          days * 7
        end
        
        def week
          weeks
        end
        
        def months
          days * 30 # approximate for basic support
        end
        
        def month
          months
        end
      end
    end
  end
end