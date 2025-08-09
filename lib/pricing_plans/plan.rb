# frozen_string_literal: true

require_relative "integer_refinements"

module PricingPlans
  class Plan
    using IntegerRefinements

    attr_reader :key, :name, :description, :bullets, :price, :price_string, :stripe_price,
                :features, :limits, :credit_inclusions, :meta,
                :cta_text, :cta_url

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
      @cta_text = nil
      @cta_url = nil
      @default = false
      @highlighted = false
    end

    # DSL methods for plan configuration
    def set_name(value)
      @name = value.to_s
    end

    def name(value = nil)
      if value.nil?
        @name || @key.to_s.titleize
      else
        set_name(value)
      end
    end

    def set_description(value)
      @description = value.to_s
    end

    def description(value = nil)
      if value.nil?
        @description
      else
        set_description(value)
      end
    end

    def set_bullets(*values)
      @bullets = values.flatten.map(&:to_s)
    end

    def bullets(*values)
      if values.empty?
        @bullets
      else
        set_bullets(*values)
      end
    end

    def set_price(value)
      @price = value
    end

    def price(value = nil)
      if value.nil?
        @price
      else
        set_price(value)
      end
    end

    def set_price_string(value)
      @price_string = value.to_s
    end

    def price_string(value = nil)
      if value.nil?
        @price_string
      else
        set_price_string(value)
      end
    end

    def set_stripe_price(value)
      case value
      when String
        @stripe_price = { id: value }
      when Hash
        @stripe_price = value
      else
        raise ConfigurationError, "stripe_price must be a string or hash"
      end
    end

    def stripe_price(value = nil)
      if value.nil?
        @stripe_price
      else
        set_stripe_price(value)
      end
    end

    def set_meta(values)
      @meta.merge!(values)
    end

    def meta(values = nil)
      if values.nil?
        @meta
      else
        set_meta(values)
      end
    end

    # CTA helpers for pricing UI
    def set_cta_text(value)
      @cta_text = value&.to_s
    end

    def cta_text(value = nil)
      if value.nil?
        @cta_text || PricingPlans.configuration.default_cta_text || default_cta_text_derived
      else
        set_cta_text(value)
      end
    end

    def set_cta_url(value)
      @cta_url = value&.to_s
    end

    def cta_url(value = nil)
      if value.nil?
        @cta_url || PricingPlans.configuration.default_cta_url || default_cta_url_derived
      else
        set_cta_url(value)
      end
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
        warn_at: options.fetch(:warn_at, [0.6, 0.8, 0.95]),
        count_scope: options[:count_scope]
      }

      validate_limit_options!(@limits[limit_key])
    end

    def limits(key=nil, **options)
      if key.nil?
        @limits
      else
        set_limit(key, **options)
      end
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

    # Plan selection sugar
    def default!(value = true)
      @default = !!value
    end

    def default?
      !!@default
    end

    def highlighted!(value = true)
      @highlighted = !!value
    end

    def highlighted?
      !!@highlighted
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

      # Validate count_scope only for persistent caps (no per-period)
      if limit[:count_scope] && limit[:per]
        raise ConfigurationError, "Limit #{limit[:key]} cannot set count_scope for per-period limits"
      end
      if limit[:count_scope]
        cs = limit[:count_scope]
        allowed = cs.respond_to?(:call) || cs.is_a?(Symbol) || cs.is_a?(Hash) || (cs.is_a?(Array) && cs.all? { |e| e.respond_to?(:call) || e.is_a?(Symbol) || e.is_a?(Hash) })
        raise ConfigurationError, "Limit #{limit[:key]} count_scope must be a Proc, Symbol, Hash, or Array of these" unless allowed
      end
    end

    def validate_pricing!
      pricing_fields = [@price, @price_string, @stripe_price].compact
      if pricing_fields.size > 1
        raise ConfigurationError, "Plan #{@key} can only have one of: price, price_string, or stripe_price"
      end
    end

    def default_cta_text_derived
      return "Subscribe" if @stripe_price
      return "Choose #{@name || @key.to_s.titleize}" if price || price_string
      return "Contact sales" if @stripe_price.nil? && !price && !price_string
      "Choose #{@name || @key.to_s.titleize}"
    end

    def default_cta_url_derived
      # If Stripe price present and Pay is used, UIs commonly route to checkout; we leave URL blank for app to decide.
      nil
    end
  end
end
