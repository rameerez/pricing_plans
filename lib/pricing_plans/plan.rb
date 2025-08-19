# frozen_string_literal: true

require_relative "integer_refinements"

module PricingPlans
  class Plan
    using IntegerRefinements

    attr_reader :key, :name, :description, :bullets, :price, :price_string, :stripe_price,
                :features, :limits, :meta,
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
      @credits_included = nil
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

    # Rails-y ergonomics for UI: expose integer cents as optional helper
    def price_cents
      return nil unless @price
      (
        if @price.respond_to?(:to_f)
          (@price.to_f * 100).round
        else
          nil
        end
      )
    end

    # Ergonomic predicate for UI/logic (free means explicit 0 price or explicit "Free" label)
    def free?
      return false if @stripe_price
      return true if @price.respond_to?(:to_i) && @price.to_i.zero?
      return true if @price_string && @price_string.to_s.strip.casecmp("Free").zero?
      false
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

    # Unified ergonomic API:
    # - Setter/getter: cta_url, cta_url("/checkout")
    # - Resolver: cta_url(billable: org)
    def cta_url(value = :__no_arg__, billable: nil)
      unless value == :__no_arg__
        set_cta_url(value)
        return @cta_url
      end

      return @cta_url if @cta_url
      default = PricingPlans.configuration.default_cta_url
      return default if default
      # New default: if host app defines subscribe_path, prefer that
      if defined?(Rails) && Rails.application.routes.url_helpers.respond_to?(:subscribe_path)
        return Rails.application.routes.url_helpers.subscribe_path(plan: key, interval: :month)
      end
      nil
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
        after_limit: options.fetch(:after_limit, :block_usage),
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

    # Credits display methods (cosmetic, for pricing UI)
    # Single-currency credits. We do not tie credits to operations here.
    def includes_credits(amount)
      @credits_included = amount.to_i
    end

    def credits_included(value = :__get__)
      if value == :__get__
        @credits_included
      else
        @credits_included = value.to_i
      end
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
      return true if @highlighted
      # Treat configuration.highlighted_plan as highlighted without consulting Registry to avoid recursion
      begin
        cfg = PricingPlans.configuration
        return true if cfg && cfg.highlighted_plan && cfg.highlighted_plan.to_sym == @key
      rescue StandardError
      end
      false
    end

    # Syntactic sugar for popular/highlighted
    def popular?
      highlighted?
    end

    # Convenience booleans used by views/hosts
    # (keep single definition above)

    def purchasable?
      !!@stripe_price || (!free? && !!@price)
    end

    # Human label to display price in UIs. Prefers explicit string, then numeric, else contact.
    def price_label
      # Auto-fetch from processor (Stripe) if enabled and plan has stripe_price
      cfg = PricingPlans.configuration
      if cfg&.auto_price_labels_from_processor && stripe_price
        begin
          if defined?(::Stripe)
            price_id = stripe_price.is_a?(Hash) ? (stripe_price[:id] || stripe_price[:month] || stripe_price[:year]) : stripe_price
            if price_id
              pr = ::Stripe::Price.retrieve(price_id)
              amount = pr.unit_amount.to_f / 100.0
              interval = pr.recurring&.interval
              suffix = interval ? "/#{interval[0,3]}" : ""
              return "$#{amount}#{suffix}"
            end
          end
        rescue StandardError
          # fallthrough to local derivation
        end
      end
      # Allow host app override via resolver
      if cfg&.price_label_resolver
        begin
          built = cfg.price_label_resolver.call(self)
          return built if built
        rescue StandardError
        end
      end
      return "Free" if price && price.to_i.zero?
      return price_string if price_string
      return "$#{price}/mo" if price
      return "Contact" if stripe_price || price.nil?
      nil
    end

    # --- New semantic pricing API ---

    # Compute semantic price parts for the given interval (:month or :year).
    # Falls back to price_string when no numeric price exists.
    def price_components(interval: :month)
      # 1) Allow app override
      if (resolver = PricingPlans.configuration.price_components_resolver)
        begin
          resolved = resolver.call(self, interval)
          return resolved if resolved
        rescue StandardError
        end
      end

      # 2) String-only prices
      if price_string
        return PricingPlans::PriceComponents.new(
          present?: false,
          currency: nil,
          amount: nil,
          amount_cents: nil,
          interval: interval,
          label: price_string,
          monthly_equivalent_cents: nil
        )
      end

      # 3) Explicit numeric price (single interval, assume monthly semantics)
      if price
        cents = price_cents
        cur = PricingPlans.configuration.default_currency_symbol
        label = if interval == :month
          "#{cur}#{price}/mo"
        else
          # Treat yearly as 12x when only a single numeric price is declared
          "#{cur}#{(price.to_f * 12).round}/yr"
        end
        return PricingPlans::PriceComponents.new(
          present?: true,
          currency: cur,
          amount: (interval == :month ? price.to_i : (price.to_f * 12).round).to_s,
          amount_cents: (interval == :month ? cents : (cents.to_i * 12)),
          interval: interval,
          label: label,
          monthly_equivalent_cents: cents
        )
      end

      # 4) Stripe price(s)
      if stripe_price
        comp = stripe_price_components(interval)
        return comp if comp
      end

      # 5) No price info at all → Contact
      PricingPlans::PriceComponents.new(
        present?: false,
        currency: nil,
        amount: nil,
        amount_cents: nil,
        interval: interval,
        label: "Contact",
        monthly_equivalent_cents: nil
      )
    end

    def monthly_price_components
      price_components(interval: :month)
    end

    def yearly_price_components
      price_components(interval: :year)
    end

    def has_interval_prices?
      sp = stripe_price
      return true if sp.is_a?(Hash) && (sp[:month] || sp[:year])
      return !price.nil? || !price_string.nil?
    end

    def has_numeric_price?
      !!price || !!stripe_price
    end

    def price_label_for(interval)
      pc = price_components(interval: interval)
      pc.label
    end

    # Stripe convenience accessors (nil when interval not present)
    def monthly_price_cents
      pc = monthly_price_components
      pc.present? ? pc.amount_cents : nil
    end

    def yearly_price_cents
      pc = yearly_price_components
      pc.present? ? pc.amount_cents : nil
    end

    def monthly_price_id
      stripe_price_id_for(:month)
    end

    def yearly_price_id
      stripe_price_id_for(:year)
    end

    def currency_symbol
      if stripe_price
        # Try to derive from Stripe API/cache; fall back to default
        pr = fetch_stripe_price_record(preferred_price_id(:month) || preferred_price_id(:year))
        if pr
          return currency_symbol_from(pr)
        end
      end
      PricingPlans.configuration.default_currency_symbol
    end

    # Plan comparison helpers for CTA ergonomics
    def current_for?(current_plan)
      return false unless current_plan
      current_plan.key.to_sym == key.to_sym
    end

    def upgrade_from?(current_plan)
      return false unless current_plan
      comparable_price_cents(self) > comparable_price_cents(current_plan)
    end

    def downgrade_from?(current_plan)
      return false unless current_plan
      comparable_price_cents(self) < comparable_price_cents(current_plan)
    end

    def downgrade_blocked_reason(from: nil, plan_owner: nil)
      return nil unless from
      allowed, reason = PricingPlans.configuration.downgrade_policy.call(from: from, to: self, plan_owner: plan_owner)
      allowed ? nil : (reason || "Downgrade not allowed")
    end

    # Pure-data view model for JS/Hotwire
    def to_view_model
      {
        id: key.to_s,
        key: key.to_s,
        name: name,
        description: description,
        features: bullets, # alias in this gem
        highlighted: highlighted?,
        default: default?,
        free: free?,
        currency: currency_symbol,
        monthly_price_cents: monthly_price_cents,
        yearly_price_cents: yearly_price_cents,
        monthly_price_id: monthly_price_id,
        yearly_price_id: yearly_price_id,
        price_label: price_label,
        price_string: price_string,
        limits: limits.transform_values { |v| v.dup }
      }
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

    # (cta_url resolver moved above with unified signature)

    def default_cta_text_derived
      return "Subscribe" if @stripe_price
      return "Choose #{@name || @key.to_s.titleize}" if price || price_string
      return "Choose plan" if @stripe_price.nil? && !price && !price_string
      "Choose #{@name || @key.to_s.titleize}"
    end

    def default_cta_url_derived
      # If Stripe price present and Pay is used, UIs commonly route to checkout; we leave URL blank for app to decide.
      nil
    end

    # --- Internal helpers for Stripe fetching and caching ---

    def stripe_price_id_for(interval)
      sp = stripe_price
      case sp
      when Hash
        case interval
        when :month then sp[:month] || sp[:id]
        when :year  then sp[:year]
        else sp[:id]
        end
      when String
        sp
      else
        nil
      end
    end

    def preferred_price_id(interval)
      stripe_price_id_for(interval)
    end

    def stripe_price_components(interval)
      return nil unless defined?(::Stripe)
      price_id = preferred_price_id(interval)
      return nil unless price_id
      pr = fetch_stripe_price_record(price_id)
      return nil unless pr
      amount_cents = (pr.unit_amount || pr.unit_amount_decimal || 0).to_i
      interval_sym = (pr.recurring&.interval == "year" ? :year : :month)
      cur = currency_symbol_from(pr)
      label = "#{cur}#{(amount_cents / 100.0).round}/#{interval_sym == :year ? 'yr' : 'mo'}"
      monthly_equiv = interval_sym == :month ? amount_cents : (amount_cents / 12.0).round
      PricingPlans::PriceComponents.new(
        present?: true,
        currency: cur,
        amount: ((amount_cents / 100.0).round).to_i.to_s,
        amount_cents: amount_cents,
        interval: interval_sym,
        label: label,
        monthly_equivalent_cents: monthly_equiv
      )
    rescue StandardError
      nil
    end

    # Normalize a plan into a comparable monthly price in cents for upgrades/downgrades
    def comparable_price_cents(plan)
      return 0 if plan.free?
      pcm = plan.monthly_price_cents
      return pcm if pcm
      pcy = plan.yearly_price_cents
      return (pcy.to_f / 12.0).round if pcy
      0
    end

    def currency_symbol_from(price_record)
      code = price_record.try(:currency).to_s.upcase
      case code
      when "USD" then "$"
      when "EUR" then "€"
      when "GBP" then "£"
      else PricingPlans.configuration.default_currency_symbol
      end
    end

    def fetch_stripe_price_record(price_id)
      cfg = PricingPlans.configuration
      cache = cfg.price_cache
      cache_key = ["pricing_plans", "stripe_price", price_id].join(":")
      if cache
        cached = safe_cache_read(cache, cache_key)
        return cached if cached
      end
      pr = ::Stripe::Price.retrieve(price_id)
      if cache
        safe_cache_write(cache, cache_key, pr, expires_in: cfg.price_cache_ttl)
      end
      pr
    end

    def safe_cache_read(cache, key)
      cache.respond_to?(:read) ? cache.read(key) : nil
    rescue StandardError
      nil
    end

    def safe_cache_write(cache, key, value, expires_in: nil)
      if cache.respond_to?(:write)
        if expires_in
          cache.write(key, value, expires_in: expires_in)
        else
          cache.write(key, value)
        end
      end
    rescue StandardError
      # ignore cache errors
    end
  end
end
