# frozen_string_literal: true

require_relative "integer_refinements"

module PricingPlans
  class Plan
    using IntegerRefinements
    
    attr_reader :key, :name, :description, :bullets, :price, :price_string, :stripe_price,
                :features, :limits, :credit_inclusions, :meta
    
    def initialize(key)
      @key = key
      @name = nil
      @description = nil
      @bullets = []
      @price = nil
      @price_string = nil
      @stripe_price = nil
      @features = Set.new
      @limits = {}
      @credit_inclusions = {}
      @meta = {}
    end
    
    # DSL methods for plan configuration
    def name(value = nil)
      return @name || @key.to_s.titleize if value.nil?
      @name = value.to_s
    end
    
    def description(value = nil)
      return @description if value.nil?
      @description = value.to_s
    end
    
    def bullets(*values)
      return @bullets if values.empty?
      @bullets = values.flatten.map(&:to_s)
    end
    
    def price(value = nil)
      return @price if value.nil?
      @price = value
    end
    
    def price_string(value = nil)
      return @price_string if value.nil?
      @price_string = value.to_s
    end
    
    def stripe_price(value = nil)
      return @stripe_price if value.nil?
      case value
      when String
        @stripe_price = { id: value }
      when Hash
        @stripe_price = value
      else
        raise ConfigurationError, "stripe_price must be a string or hash"
      end
    end
    
    def meta(values = nil)
      return @meta if values.nil?
      @meta.merge!(values)
    end
    
    # Feature methods
    def allows(*feature_keys)
      feature_keys.flatten.each do |key|
        @features.add(key.to_sym)
      end
    end
    
    def allow(*feature_keys)
      allows(*feature_keys)
    end
    
    def disallows(*feature_keys)
      feature_keys.flatten.each do |key|
        @features.delete(key.to_sym)
      end
    end
    
    def disallow(*feature_keys)
      disallows(*feature_keys)
    end
    
    def allows_feature?(feature_key)
      @features.include?(feature_key.to_sym)
    end
    
    # Limit methods  
    def set_limit(key, **options)
      limit_key = key.to_sym
      @limits[limit_key] = {
        key: limit_key,
        to: options[:to],
        per: options[:per],
        after_limit: options.fetch(:after_limit, :grace_then_block),
        grace: options.fetch(:grace, 7.days),
        warn_at: options.fetch(:warn_at, [0.6, 0.8, 0.95])
      }
      
      validate_limit_options!(@limits[limit_key])
    end
    
    def limits(key=nil, **options)
      return @limits if key.nil?
      set_limit(key, **options)
    end
    
    def limit(key, **options)
      set_limit(key, **options)
    end
    
    def unlimited(*keys)
      keys.flatten.each do |key|
        set_limit(key.to_sym, to: :unlimited)
      end
    end
    
    def limit_for(key)
      @limits[key.to_sym]
    end
    
    # Credits methods
    def includes_credits(amount, for:)
      operation_key = binding.local_variable_get(:for).to_sym
      @credit_inclusions[operation_key] = {
        amount: amount,
        operation: operation_key
      }
    end
    
    def credit_inclusion_for(operation_key)
      @credit_inclusions[operation_key.to_sym]
    end
    
    def validate!
      validate_limits!
      validate_pricing!
    end
    
    private
    
    def validate_limits!
      @limits.each do |key, limit|
        validate_limit_options!(limit)
      end
    end
    
    def validate_limit_options!(limit)
      # Validate to: value
      unless limit[:to] == :unlimited || limit[:to].is_a?(Integer) || (limit[:to].respond_to?(:to_i) && !limit[:to].is_a?(String))
        raise ConfigurationError, "Limit #{limit[:key]} 'to' must be :unlimited, Integer, or respond to to_i"
      end
      
      # Validate after_limit values
      valid_after_limit = [:grace_then_block, :block_usage, :just_warn]
      unless valid_after_limit.include?(limit[:after_limit])
        raise ConfigurationError, "Limit #{limit[:key]} after_limit must be one of #{valid_after_limit.join(', ')}"
      end
      
      # Validate grace only applies to blocking behaviors
      if limit[:grace] && limit[:after_limit] == :just_warn
        raise ConfigurationError, "Limit #{limit[:key]} cannot have grace with :just_warn after_limit"
      end
      
      # Validate warn_at thresholds
      if limit[:warn_at] && !limit[:warn_at].all? { |t| t.is_a?(Numeric) && t.between?(0, 1) }
        raise ConfigurationError, "Limit #{limit[:key]} warn_at thresholds must be numbers between 0 and 1"
      end
    end
    
    def validate_pricing!
      pricing_fields = [@price, @price_string, @stripe_price].compact
      if pricing_fields.size > 1
        raise ConfigurationError, "Plan #{@key} can only have one of: price, price_string, or stripe_price"
      end
    end
  end
end