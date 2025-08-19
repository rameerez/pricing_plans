# frozen_string_literal: true

PricingPlans.configure do |config|
  # Example plans
  plan :free do
    price 0

    description   "Perfect for getting started"
    bullets       "Basic features", "Community support"

    limits :projects, to: 3, after_limit: :block_usage
    # Example scoped persistent cap (active-only rows)
    # limits :projects, to: 3, count_scope: { status: "active" }
    default!
  end

  plan :pro do
    description   "For growing teams and businesses"
    bullets       "Advanced features", "Priority support", "API access"

    allows :api_access, :premium_features
    limits :projects, to: 25, after_limit: :grace_then_block, grace: 7.days

    highlighted!
  end

  plan :enterprise do
    price_string  "Contact us"

    description   "Get in touch and we'll fit your needs."
    bullets       "Custom limits", "Dedicated SLAs", "Dedicated support"
    cta_text      "Contact sales"
    cta_url       "mailto:sales@example.com"

    unlimited :projects
    allows    :api_access, :premium_features
  end


  # Optional settings

  # Optional: global controller plan owner resolver (per-controller still wins)
  # Either a symbol helper name or a block evaluated in the controller
  # config.controller_plan_owner :current_organization
  # or
  # config.controller_plan_owner { current_account }

  # Period cycle for per-period limits
  # :billing_cycle, :calendar_month, :calendar_week, :calendar_day
  # Global default period for per-period limits (can be overridden per limit via `per:`)
  # config.period_cycle = :billing_cycle

  # Optional defaults for pricing UI calls‑to‑action
  # config.default_cta_text = "Choose plan"
  # config.default_cta_url  = nil # e.g., "/pricing" or your billing path
  #
  # By convention, if your app defines `subscribe_path(plan:, interval:)`,
  # `plan.cta_url` will automatically point to it (default interval :month).
  # See README: Controller‑first Stripe Checkout wiring.

  # Controller ergonomics — global default redirect when a limit blocks
  # Accepts:
  #   - Symbol: a controller helper method, e.g. :pricing_path
  #   - String: a path or URL, e.g. "/pricing"
  #   - Proc: instance-exec'd in the controller with the Result: ->(result) { pricing_path }
  # Examples:
  # config.redirect_on_blocked_limit = :pricing_path
  # config.redirect_on_blocked_limit = "/pricing"
  # config.redirect_on_blocked_limit = ->(result) { pricing_path }


  #`config.message_builder` lets apps override human copy for `:over_limit`, `:grace`, `:feature_denied`, and overage report; used broadly across guards/UX.


  # Optional event callbacks -- enqueue jobs here to send notifications or emails when certain events happen
  # config.on_warning(:products)     { |org, threshold| PlanMailer.quota_warning(org, :products, threshold).deliver_later }
  # config.on_grace_start(:products) { |org, ends_at|   PlanMailer.grace_started(org, :products, ends_at).deliver_later  }
  # config.on_block(:products)       { |org|            PlanMailer.blocked(org, :products).deliver_later                 }

  # --- Pricing semantics (UI-agnostic) ---
  # Currency symbol to use when Stripe is absent
  # config.default_currency_symbol = "$"

  # Cache for Stripe Price lookups (defaults to Rails.cache when available)
  # config.price_cache = Rails.cache
  # TTL for Stripe price cache (seconds)
  # config.price_cache_ttl = 10.minutes

  # Build semantic price parts yourself (optional). Return a PricingPlans::PriceComponents or nil to fallback
  # config.price_components_resolver = ->(plan, interval) { nil }

  # Free copy helper (used by some view-models)
  # config.free_price_caption = "Forever free"

  # Default UI interval for toggles
  # config.interval_default_for_ui = :month # or :year

  # Downgrade policy hook used by CTA ergonomics helpers
  # config.downgrade_policy = ->(from:, to:, plan_owner:) { [true, nil] }
end
