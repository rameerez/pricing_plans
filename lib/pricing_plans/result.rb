# frozen_string_literal: true

module PricingPlans
  class Result
    STATES = [:within, :warning, :grace, :blocked].freeze
    
    attr_reader :state, :message, :limit_key, :billable, :metadata
    
    def initialize(state:, message:, limit_key: nil, billable: nil, metadata: {})
      unless STATES.include?(state)
        raise ArgumentError, "Invalid state: #{state}. Must be one of: #{STATES}"
      end
      
      @state = state
      @message = message
      @limit_key = limit_key
      @billable = billable
      @metadata = metadata
    end
    
    def ok?
      @state == :within
    end
    
    def warning?
      @state == :warning
    end
    
    def grace?
      @state == :grace
    end
    
    def blocked?
      @state == :blocked
    end
    
    def success?
      ok? || warning? || grace?
    end
    
    def failure?
      blocked?
    end
    
    # Helper methods for view rendering
    def css_class
      case @state
      when :within
        "success"
      when :warning
        "warning"
      when :grace
        "warning"
      when :blocked
        "error"
      end
    end
    
    def icon
      case @state
      when :within
        "✓"
      when :warning
        "⚠"
      when :grace
        "⏳"
      when :blocked
        "🚫"
      end
    end
    
    def to_h
      {
        state: @state,
        message: @message,
        limit_key: @limit_key,
        metadata: @metadata,
        ok: ok?,
        warning: warning?,
        grace: grace?,
        blocked: blocked?
      }
    end
    
    def inspect
      "#<PricingPlans::Result state=#{@state} message=\"#{@message}\">"
    end
    
    class << self
      def within(message = "Within limit", **options)
        new(state: :within, message: message, **options)
      end
      
      def warning(message, **options)
        new(state: :warning, message: message, **options)
      end
      
      def grace(message, **options)
        new(state: :grace, message: message, **options)
      end
      
      def blocked(message, **options)
        new(state: :blocked, message: message, **options)
      end
    end
  end
end