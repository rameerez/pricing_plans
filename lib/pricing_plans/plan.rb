# frozen_string_literal: true

require_relative "integer_refinements"

module PricingPlans
  class Plan
    using IntegerRefinements

    # Every billing interval a plan can be priced in, in display order.
    BILLING_INTERVALS = %i[day week month quarter year].freeze

    # How many months one interval spans, to express any price per month.
    MONTHS_PER_INTERVAL = {
      day: Rational(12, 365),
      week: Rational(12, 52),
      month: 1,
      quarter: 3,
      year: 12
    }.freeze

    INTERVAL_SUFFIXES = { day: "/day", week: "/wk", month: "/mo", quarter: "/qtr", year: "/yr" }.freeze

    attr_reader :key, :features

    def initialize(key)
      @key = key
      @name = nil
      @description = nil
      @bullets = []
      @prices = {}.freeze
      @price_declared_per_interval = false
      @price_string = nil
      @stripe_price = nil
      @features = Set.new
      @grandfathers = {}
      @limits = {}
      @credits_included = nil
      @meta = {}
      @cta_text = nil
      @cta_url = nil
      @default = false
      @highlighted = false
      @hidden = false
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

    # `price 24` is shorthand for `price month: 24`. Declare each interval you
    # sell to price it for real instead of deriving it from the monthly number:
    #
    #   price month: 24, quarter: 54, year: 108
    def set_price(value)
      @price_declared_per_interval = value.is_a?(Hash)
      @prices =
        if value.is_a?(Hash) then normalize_interval_prices(value)
        elsif value.nil? then {}.freeze
        else { month: value }.freeze
        end
    end

    # The monthly amount (nil when the plan declares no monthly price).
    # Every declared interval lives in #prices.
    def price(value = nil)
      if value.nil?
        @prices[:month]
      else
        set_price(value)
      end
    end

    # Locally declared amounts by interval, in display order: { month: 24, quarter: 54 }
    attr_reader :prices

    # Rails-y ergonomics for UI: expose integer cents as optional helper
    def price_cents
      cents_for(price)
    end

    # Ergonomic predicate for UI/logic (free means explicit 0 price or explicit "Free" label)
    def free?
      return false if @stripe_price
      return true if local_price? && @prices.values.all? { |amount| amount.respond_to?(:to_i) && amount.to_i.zero? }
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
        @stripe_price = normalize_stripe_price_keys(value)
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

    alias_method :set_metadata, :set_meta
    alias_method :metadata, :meta

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
    # - Resolver: cta_url(plan_owner: org), cta_url(interval: :quarter)
    def cta_url(value = :__no_arg__, plan_owner: nil, interval: :month)
      unless value == :__no_arg__
        set_cta_url(value)
        return @cta_url
      end

      interval = normalize_billing_interval(interval)
      return @cta_url if @cta_url
      default = PricingPlans.configuration.default_cta_url
      return default if default
      # New default: if host app defines subscribe_path, prefer that
      if defined?(Rails) && Rails.respond_to?(:application) && Rails.application && Rails.application.routes.url_helpers.respond_to?(:subscribe_path)
        return Rails.application.routes.url_helpers.subscribe_path(plan: key, interval: interval)
      end
      nil
    end

    # Feature methods
    def allows(*feature_keys)
      feature_keys.flatten.each do |key|
        unless key.is_a?(Symbol) || key.is_a?(String)
          raise ConfigurationError,
                "`allows` takes feature names only (got #{key.inspect}). Plan quotas live in " \
                "`limits`; per-owner capacities live on feature passes (`issue_feature_pass!(..., limits: {})`)."
        end
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

    # Grandfathering: declare that owners whose qualifying pricing
    # relationship predates the cutoff keep a feature the plan no longer
    # carries. Pure config — no database state, no backfill, no rake task.
    # The pricing history stays readable in the initializer forever:
    #
    #   plan :indie do
    #     allows :api_access                # :distribution removed 2026-08-31
    #     grandfather :distribution, subscribed_before: "2026-09-01"
    #   end
    #
    # The cutoff accepts a Time, Date, or String; date-only values are read
    # as midnight UTC. The relationship timestamp comes from the current
    # assignment and/or same-plan subscription. Those records keep created_at
    # across in-place plan/price changes, so this models a continuous pricing
    # relationship rather than unavailable plan-change history. For an exact
    # materialized cohort or a promise that must survive anything, use an
    # explicit per-owner grant instead: `owner.grant_feature!(:distribution)`.
    def grandfather(feature_key, subscribed_before:)
      @grandfathers[feature_key.to_sym] = normalize_grandfather_cutoff(subscribed_before)
    end

    def grandfathered_features
      @grandfathers.keys
    end

    def grandfather_cutoff_for(feature_key)
      @grandfathers[feature_key.to_sym]
    end

    def grandfathers_feature?(feature_key, relationship_started_at:)
      cutoff = grandfather_cutoff_for(feature_key)
      return false unless cutoff && relationship_started_at

      relationship_started_at < cutoff
    end

    # Limit methods
    def set_limit(key, **options)
      limit_key = key.to_sym
      after_limit = options.fetch(:after_limit, :block_usage)

      # Grace only exists for :grace_then_block. Defaulting it onto every
      # limit made `limit[:grace]` a lie for :block_usage/:just_warn limits
      # (enforcement ignores it there), and downstream consumers reading the
      # config naively would promise customers a grace window that does not
      # exist. Explicit grace on a non-grace mode raises immediately, even if
      # the caller supplied nil/false (truthiness must not erase intent).
      if %i[block_usage just_warn].include?(after_limit) && options.key?(:grace)
        raise ConfigurationError,
              "Limit #{limit_key} cannot have grace with :#{after_limit} after_limit " \
              "(grace only applies to :grace_then_block)"
      end

      limit = {
        key: limit_key,
        to: options[:to],
        per: options[:per],
        after_limit: after_limit,
        grace: after_limit == :grace_then_block ? options.fetch(:grace, 7.days) : nil,
        warn_at: options.fetch(:warn_at, [0.6, 0.8, 0.95]),
        count_scope: options[:count_scope]
      }

      validate_limit_options!(limit)
      @limits[limit_key] = limit
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

    def hidden!(value = true)
      @hidden = !!value
    end

    def hidden?
      !!@hidden
    end

    # Syntactic sugar for popular/highlighted
    def popular?
      highlighted?
    end

    # Convenience booleans used by views/hosts
    # (keep single definition above)

    def purchasable?
      !!@stripe_price || (!free? && local_price?)
    end

    # Human label to display price in UIs. Prefers explicit string, then numeric, else contact.
    def price_label
      # Auto-fetch from processor (Stripe) if enabled and plan has stripe_price.
      # A locally declared numeric price wins: it is the source of truth for
      # display, and honoring it keeps rendering off the network entirely.
      cfg = PricingPlans.configuration
      if cfg&.auto_price_labels_from_processor && stripe_price && !local_price?
        begin
          if defined?(::Stripe)
            price_id = price_ids.first
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
      return price_label_for(@prices.keys.first) if local_price?
      return "Contact" if stripe_price || price.nil?
      nil
    end

    # --- New semantic pricing API ---

    # Compute semantic price parts for the given interval (any of
    # BILLING_INTERVALS; strings like params[:interval] are accepted).
    # Falls back to price_string when no numeric price exists.
    def price_components(interval: :month)
      interval = normalize_billing_interval(interval)

      # 1) Allow app override
      if (resolver = PricingPlans.configuration.price_components_resolver)
        begin
          resolved = resolver.call(self, interval)
          return resolved if resolved
        rescue StandardError
        end
      end

      # 2) String-only prices
      return missing_price_components(interval, label: price_string) if price_string

      # 3) Locally declared price. A declared interval is the real amount; an
      #    undeclared one is derived from the monthly price when there is one.
      if local_price?
        cur = PricingPlans.configuration.default_currency_symbol
        if @prices.key?(interval)
          cents = cents_for(@prices[interval])
          return local_price_components(cents, interval, cur, amount: (cents / 100).to_s)
        elsif price
          cents = (price_cents * MONTHS_PER_INTERVAL[interval]).round
          return local_price_components(cents, interval, cur, amount: (cents / 100.0).round.to_s, monthly_equivalent_cents: price_cents)
        else
          return missing_price_components(interval, label: nil)
        end
      end

      # 4) Stripe price(s)
      if stripe_price
        comp = stripe_price_components(interval)
        return comp if comp
      end

      # 5) No price info at all → Contact
      missing_price_components(interval, label: "Contact")
    end

    def monthly_price_components
      price_components(interval: :month)
    end

    def yearly_price_components
      price_components(interval: :year)
    end

    def has_interval_prices?
      sp = stripe_price
      return true if sp.is_a?(Hash) && BILLING_INTERVALS.any? { |interval| sp[interval] }
      return local_price? || !price_string.nil?
    end

    def has_numeric_price?
      local_price? || !!stripe_price
    end

    # Intervals this plan is sold in, in display order: the ones declared in
    # `price` plus the ones with a Stripe price id (a single id, or `id:`,
    # counts as monthly). Drive your interval toggle from this.
    def billing_intervals
      BILLING_INTERVALS & (@prices.keys | stripe_billing_intervals)
    end

    # Stripe price id to check out for the given interval (nil when absent).
    def price_id_for(interval)
      stripe_price_id_for(normalize_billing_interval(interval))
    end

    # Every Stripe price id declared on this plan.
    def price_ids
      case stripe_price
      when Hash then stripe_price.values.compact.uniq
      when String then [stripe_price]
      else []
      end
    end

    # The interval under which this plan declares `price_id` (nil when the id
    # is not one of this plan's). A single id, or `id:`, counts as monthly.
    def billing_interval_for(price_id)
      return nil if price_id.blank?

      case stripe_price
      when String then :month if stripe_price == price_id
      when Hash
        key = stripe_price.key(price_id)
        key == :id ? :month : key
      end
    end

    # The plan's per-month cost in cents from its locally declared `price`:
    # the monthly amount when declared, else the cheapest per-month equivalent
    # among the declared intervals. nil without a local price.
    def monthly_equivalent_cents
      return nil unless local_price?
      return price_cents if price

      @prices.map { |interval, amount| monthly_cents_from(cents_for(amount), interval) }.min
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
      # A locally declared numeric price is rendered in the configured currency
      # (see #price_components), so don't ask Stripe when we have one.
      if stripe_price && !local_price?
        # Try to derive from Stripe API/cache; fall back to default
        begin
          pr = fetch_stripe_price_record(preferred_price_id(:month) || price_ids.first)
          if pr
            return currency_symbol_from(pr)
          end
        rescue StandardError
          # Stripe unreachable, rate-limited or unconfigured: never take down a pricing page
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
        metadata: metadata.dup,
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
        billing_intervals: billing_intervals,
        interval_prices: interval_prices_view_model,
        limits: limits.transform_values { |v| v.dup }
      }
    end

    def validate!
      validate_limits!
      validate_pricing!
      validate_grandfathers!
    end

    private

    def normalize_grandfather_cutoff(value)
      cutoff =
        if defined?(ActiveSupport::TimeWithZone) && value.is_a?(ActiveSupport::TimeWithZone)
          value.utc.to_time
        else
          case value
          when Time then value
          when Date, String then value.to_time(:utc)
          else
            raise ConfigurationError,
                  "grandfather cutoff must be a Time, ActiveSupport::TimeWithZone, Date, or String " \
                  "(got #{value.class})"
          end
        end

      raise ConfigurationError, "grandfather cutoff #{value.inspect} is not a parseable time" unless cutoff.is_a?(Time)

      cutoff
    rescue ArgumentError
      raise ConfigurationError, "grandfather cutoff #{value.inspect} is not a parseable time"
    end

    def validate_grandfathers!
      contradiction = @grandfathers.keys & @features.to_a
      return if contradiction.empty?

      raise ConfigurationError,
            "Plan #{key.inspect} grandfathers #{contradiction.inspect} but also allows " \
            "them via `allows`. Grandfathering is for features the plan no longer " \
            "carries — remove them from `allows` (everyone has them) or from " \
            "`grandfather` (nobody needs the exception)."
    end

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

      # Grace only applies to :grace_then_block; anywhere else it would be
      # stored but never honored, which is worse than an error.
      if limit[:grace] && limit[:after_limit] != :grace_then_block
        raise ConfigurationError,
              "Limit #{limit[:key]} cannot have grace with :#{limit[:after_limit]} after_limit " \
              "(grace only applies to :grace_then_block)"
      end

      if limit[:after_limit] == :grace_then_block && !valid_grace_window?(limit[:grace])
        raise ConfigurationError,
              "Limit #{limit[:key]} grace must be a positive duration of at least one second"
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

    def valid_grace_window?(grace)
      grace.is_a?(Numeric) && grace.finite? && grace.to_i.positive?
    rescue TypeError, RangeError
      false
    end

    def validate_pricing!
      # `price` and `stripe_price` are not alternatives: the number is the local
      # source of truth for display and plan comparison (resolved with no network
      # call), while the Stripe id stays the billing identity used by checkout and
      # by subscription -> plan matching. Only `price_string` remains exclusive,
      # since it is a label that cannot be compared numerically.
      if @price_string && (local_price? || @stripe_price)
        raise ConfigurationError, "Plan #{@key} can only have one of: price, price_string, or stripe_price"
      end

      validate_interval_prices_match_stripe!
    end

    # Once `price` is declared per interval, it is a claim about every interval
    # the plan sells. An interval with a Stripe id but no local amount would be
    # displayed as a derived number Stripe does not charge; a local amount with
    # no Stripe id would be displayed but could not be checked out.
    def validate_interval_prices_match_stripe!
      return unless @price_declared_per_interval && @stripe_price

      priced_only = @prices.keys - stripe_billing_intervals
      billed_only = stripe_billing_intervals - @prices.keys
      return if priced_only.empty? && billed_only.empty?

      problems = []
      problems << "no stripe_price for #{format_interval_list(priced_only)}" if priced_only.any?
      problems << "no price for #{format_interval_list(billed_only)}" if billed_only.any?
      raise ConfigurationError,
            "Plan #{@key.inspect} declares price and stripe_price for different intervals " \
            "(#{problems.join('; ')}). Declare every interval you sell in both, e.g. " \
            "`price month: 24, year: 108` with `stripe_price month: \"price_...\", year: \"price_...\"`."
    end

    def local_price?
      !@prices.empty?
    end

    # Intervals with a Stripe price id; a single id, or `id:`, counts as monthly.
    def stripe_billing_intervals
      case @stripe_price
      when Hash then @stripe_price.keys.map { |key| key == :id ? :month : key }.uniq
      when String then [:month]
      else []
      end
    end

    def cents_for(amount)
      return nil if amount.nil? || !amount.respond_to?(:to_f)

      (amount.to_f * 100).round
    end

    def monthly_cents_from(cents, interval)
      (cents / MONTHS_PER_INTERVAL.fetch(interval)).round
    end

    def format_price(cents, currency)
      whole, fraction = cents.to_i.divmod(100)
      fraction.zero? ? "#{currency}#{whole}" : format("%<currency>s%<whole>d.%<fraction>02d", currency:, whole:, fraction:)
    end

    def format_interval_list(intervals)
      intervals.map(&:inspect).join(", ")
    end

    # Runtime intervals (price_components, price_id_for, cta_url) usually come
    # from a URL (`params[:interval]`), so an unknown or blank one falls back
    # to :month instead of raising: a hand-edited `?interval=foo` shows the
    # monthly price rather than a 500. Typos in the CONFIG still raise at boot
    # (normalize_interval_prices / the stripe_price key check).
    def normalize_billing_interval(interval)
      normalized = interval.respond_to?(:to_sym) && interval.to_s.strip != "" ? interval.to_s.strip.to_sym : nil
      return normalized if BILLING_INTERVALS.include?(normalized)

      log_unknown_interval(interval) unless interval.nil?
      :month
    end

    def log_unknown_interval(interval)
      message = "[PricingPlans] Unknown billing interval #{interval.inspect} for plan #{key.inspect}; " \
                "using :month (known: #{format_interval_list(BILLING_INTERVALS)})"
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.debug(message)
      end
    rescue StandardError
      nil
    end

    def normalize_interval_prices(value)
      raise ConfigurationError, "Plan #{@key.inspect} price hash is empty" if value.empty?

      amounts = value.to_h { |interval, amount| [interval.to_sym, amount] }
      unknown = amounts.keys - BILLING_INTERVALS
      if unknown.any?
        raise ConfigurationError,
              "Plan #{@key.inspect} price uses unknown billing interval #{format_interval_list(unknown)}; " \
              "use any of #{format_interval_list(BILLING_INTERVALS)}"
      end

      amounts.each do |interval, amount|
        next if amount.is_a?(Numeric) && amount.real? && amount.finite? && !amount.negative?

        raise ConfigurationError,
              "Plan #{@key.inspect} price for #{interval} must be a non-negative number (got #{amount.inspect})"
      end

      BILLING_INTERVALS.filter_map { |interval| [interval, amounts[interval]] if amounts.key?(interval) }.to_h.freeze
    end

    def normalize_stripe_price_keys(value)
      normalized = value.transform_keys(&:to_sym)
      allowed = BILLING_INTERVALS + [:id]
      unknown = normalized.keys - allowed
      if unknown.any?
        raise ConfigurationError,
              "Plan #{@key.inspect} stripe_price uses unknown key #{format_interval_list(unknown)}; " \
              "use any of #{format_interval_list(allowed)}"
      end
      normalized
    end

    def local_price_components(cents, interval, currency, amount:, monthly_equivalent_cents: nil)
      monthly = monthly_equivalent_cents || monthly_cents_from(cents, interval)
      PricingPlans::PriceComponents.new(
        present?: true,
        currency: currency,
        amount: amount,
        amount_cents: cents,
        interval: interval,
        label: "#{format_price(cents, currency)}#{INTERVAL_SUFFIXES[interval]}",
        monthly_equivalent_cents: monthly,
        monthly_equivalent_label: "#{format_price(monthly, currency)}/mo"
      )
    end

    def missing_price_components(interval, label:)
      PricingPlans::PriceComponents.new(
        present?: false,
        currency: nil,
        amount: nil,
        amount_cents: nil,
        interval: interval,
        label: label,
        monthly_equivalent_cents: nil,
        monthly_equivalent_label: nil
      )
    end

    def interval_prices_view_model
      billing_intervals.to_h do |interval|
        pc = price_components(interval: interval)
        [interval, {
          amount_cents: pc.present? ? pc.amount_cents : nil,
          monthly_equivalent_cents: pc.monthly_equivalent_cents,
          label: pc.label,
          monthly_equivalent_label: pc.monthly_equivalent_label,
          price_id: price_id_for(interval)
        }]
      end
    end

    # (cta_url resolver moved above with unified signature)

    def default_cta_text_derived
      return "Subscribe" if @stripe_price
      return "Choose #{@name || @key.to_s.titleize}" if local_price? || price_string
      return "Choose plan" if @stripe_price.nil? && !local_price? && !price_string
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
        interval == :month ? (sp[:month] || sp[:id]) : sp[interval]
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
      interval_sym, months = stripe_billing_period(pr.recurring, fallback: interval)
      cur = currency_symbol_from(pr)
      monthly_equiv = (amount_cents / months).round
      PricingPlans::PriceComponents.new(
        present?: true,
        currency: cur,
        amount: ((amount_cents / 100.0).round).to_i.to_s,
        amount_cents: amount_cents,
        interval: interval_sym,
        label: "#{format_price(amount_cents, cur)}#{INTERVAL_SUFFIXES[interval_sym]}",
        monthly_equivalent_cents: monthly_equiv,
        monthly_equivalent_label: "#{format_price(monthly_equiv, cur)}/mo"
      )
    rescue StandardError
      nil
    end

    # Stripe expresses a quarter as `interval: "month", interval_count: 3`.
    # Returns [interval_symbol, months_in_one_billing_period].
    def stripe_billing_period(recurring, fallback:)
      return [:month, 1] unless recurring

      unit = recurring.interval.to_s.to_sym
      count = recurring.respond_to?(:interval_count) ? recurring.interval_count.to_i : 1
      count = 1 unless count.positive?
      return [:month, 1] unless MONTHS_PER_INTERVAL.key?(unit)

      months = MONTHS_PER_INTERVAL[unit] * count
      interval = MONTHS_PER_INTERVAL.key(months) if %i[month year].include?(unit)
      interval ||= count == 1 ? unit : fallback
      [interval, months]
    end

    # Normalize a plan into a comparable monthly price in cents for upgrades/downgrades
    def comparable_price_cents(plan)
      plan.comparable_monthly_cents
    end

    protected

    # Monthly cost used to rank plans: the declared (or Stripe) monthly price,
    # else the cheapest per-month equivalent of the intervals the plan is sold
    # in. Goes through #price_components so price_components_resolver applies.
    def comparable_monthly_cents
      return 0 if free?

      cents = monthly_cents_of(price_components(interval: :month))
      cents ||= (billing_intervals - [:month]).filter_map { |i| monthly_cents_of(price_components(interval: i)) }.min
      return cents if cents

      warn_about_zero_comparison
      0
    end

    private

    def monthly_cents_of(components)
      return nil unless components.present?

      components.monthly_equivalent_cents || (components.amount_cents if components.interval == :month)
    end

    # A paid plan priced only by Stripe compares as $0 whenever the live lookup
    # fails, which makes upgrade CTAs vanish without an error. Say so once.
    def warn_about_zero_comparison
      return if @zero_comparison_warned || !stripe_price || local_price?

      @zero_comparison_warned = true
      message = "[PricingPlans] Plan #{key.inspect} has only a stripe_price, and its Stripe price could not be " \
                "resolved, so upgrade_from?/downgrade_from? compare it as $0. Declare `price` alongside " \
                "`stripe_price` (e.g. `price month: 24, year: 108`) to compare plans without calling Stripe."
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      else
        Kernel.warn(message)
      end
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
