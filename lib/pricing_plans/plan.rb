# frozen_string_literal: true

module PricingPlans
  class Plan

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

    # DSL methods for plan configuration (getter/setter duals)
    def name(value = nil)
      return (@name || @key.to_s.titleize) if value.nil?
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

    # CTA helpers for pricing UI
    def cta_text(value = nil)
      return (@cta_text || PricingPlans.configuration.default_cta_text || default_cta_text_derived) if value.nil?
      @cta_text = value&.to_s
    end

    # Unified ergonomic API:
    # - Setter/getter: cta_url, cta_url("/checkout")
    # - Resolver: cta_url(view: view_context, billable: org)
    def cta_url(value = :__no_arg__, view: nil, billable: nil)
      unless value == :__no_arg__
        @cta_url = value&.to_s
        return @cta_url
      end

      return @cta_url if @cta_url
      default = PricingPlans.configuration.default_cta_url
      return default if default
      # best-effort auto
      if PricingPlans.configuration.auto_cta_with_pay
        begin
          gen = PricingPlans.configuration.auto_cta_with_pay
          if gen.respond_to?(:call)
            case gen.arity
            when 3 then return gen.call(billable, self, view)
            when 2 then return gen.call(billable, self)
            else        return gen.call(billable)
            end
          end
        rescue StandardError
        end
      end
      nil
    end

    # Feature methods
    def allows(*feature_keys)
      feature_keys.flatten.each { |key| @features.add(key.to_sym) }
    end
    def allow(*feature_keys); allows(*feature_keys); end

    def disallows(*feature_keys)
      feature_keys.flatten.each { |key| @features.delete(key.to_sym) }
    end
    def disallow(*feature_keys); disallows(*feature_keys); end

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
      return @limits if key.nil?
      set_limit(key, **options)
    end
    def limit(key, **options); set_limit(key, **options); end

    def unlimited(*keys)
      keys.flatten.each { |key| set_limit(key.to_sym, to: :unlimited) }
    end

    def limit_for(key)
      @limits[key.to_sym]
    end

    # Credits methods
    def includes_credits(amount, for:)
      operation_key = binding.local_variable_get(:for).to_sym
      @credit_inclusions[operation_key] = { amount: amount, operation: operation_key }
    end

    def credit_inclusion_for(operation_key)
      @credit_inclusions[operation_key.to_sym]
    end

    # Plan selection sugar
    def default!(value = true); @default = !!value; end
    def default?; !!@default; end

    def highlighted!(value = true); @highlighted = !!value; end
    def highlighted?; !!@highlighted; end

    def free?
      @price.respond_to?(:to_i) && @price.to_i.zero?
    end

    def purchasable?
      !!@stripe_price || (!free? && !!@price)
    end

    def validate!
      validate_limits!
      validate_pricing!
    end

    private
    def validate_limits!
      @limits.each { |_, limit| validate_limit_options!(limit) }
    end

    def validate_limit_options!(limit)
      unless limit[:to] == :unlimited || limit[:to].is_a?(Integer) || (limit[:to].respond_to?(:to_i) && !limit[:to].is_a?(String))
        raise ConfigurationError, "Limit #{limit[:key]} 'to' must be :unlimited, Integer, or respond to to_i"
      end

      valid_after_limit = [:grace_then_block, :block_usage, :just_warn]
      unless valid_after_limit.include?(limit[:after_limit])
        raise ConfigurationError, "Limit #{limit[:key]} after_limit must be one of #{valid_after_limit.join(', ')}"
      end

      if limit[:grace] && limit[:after_limit] == :just_warn
        raise ConfigurationError, "Limit #{limit[:key]} cannot have grace with :just_warn after_limit"
      end

      if limit[:warn_at] && !limit[:warn_at].all? { |t| t.is_a?(Numeric) && t.between?(0, 1) }
        raise ConfigurationError, "Limit #{limit[:key]} warn_at thresholds must be numbers between 0 and 1"
      end

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
  end
end
