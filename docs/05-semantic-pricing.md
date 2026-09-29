# Semantic pricing

Building delightful pricing UIs usually needs structured price parts (currency, amount, interval) and data for every interval you sell (monthly, quarterly, yearly…). `pricing_plans` ships a semantic, UI‑agnostic API so you don't have to parse price strings in your app.

## Value object: `PricingPlans::PriceComponents`

Structure returned by the helpers below:

```ruby
PricingPlans::PriceComponents = Struct.new(
  :present?,                 # boolean: price is numeric?
  :currency,                 # string currency symbol, e.g. "$", "€"
  :amount,                   # string whole amount, e.g. "29"
  :amount_cents,             # integer cents, e.g. 2900
  :interval,                 # :day | :week | :month | :quarter | :year
  :label,                    # friendly label, e.g. "$29/mo", "$54/qtr" or "Contact"
  :monthly_equivalent_cents, # integer; the amount per month, e.g. 1800 for $54/qtr
  :monthly_equivalent_label, # string; e.g. "$18/mo"
  keyword_init: true
)
```

Labels use `/day`, `/wk`, `/mo`, `/qtr` and `/yr`, and keep cents when there are any (`$19.99/mo`, `$49.50/qtr`).

## Semantic pricing helpers

```ruby
plan.price_components(interval: :month)    # => PriceComponents (any billing interval; "quarter" strings work too)
plan.monthly_price_components              # sugar for :month
plan.yearly_price_components               # sugar for :year

plan.prices                                # { month: 24, quarter: 54, year: 108 }
plan.billing_intervals                     # [:month, :quarter, :year]
plan.price_id_for(:quarter)                # Stripe Price ID for that interval
plan.monthly_equivalent_cents              # cheapest local per-month price, in cents

plan.has_interval_prices?                  # true if configured/inferred
plan.has_numeric_price?                    # true if numeric (price or stripe_price)

plan.price_label_for(:month)               # "$29/mo" (uses PriceComponents)
plan.price_label_for(:year)                # "$290/yr" or Stripe-derived

plan.monthly_price_cents                   # integer or nil
plan.yearly_price_cents                    # integer or nil
plan.monthly_price_id                      # Stripe Price ID (when available)
plan.yearly_price_id
plan.currency_symbol                       # "$" or derived from Stripe
```

Notes:

- If `stripe_price` is configured, we derive cents, currency, and interval from the Stripe Price (and cache it). Stripe's `interval: "month", interval_count: 3` reads as `:quarter`.
- If `price` is declared alongside `stripe_price`, the local numbers win and no Stripe call is made. Declare every interval you sell (`price month: 24, quarter: 54, year: 108`) to show real discounted amounts; with a single `price 24`, other intervals are derived from the monthly number (12× for yearly).
- An unknown or blank interval falls back to `:month` (logged at debug level), so passing `params[:interval]` straight through is safe: a hand-edited `?interval=foo` shows the monthly price instead of an error. To offer only the intervals a plan sells, list `plan.billing_intervals`. Unknown intervals in the plan *configuration* still raise a `ConfigurationError` at boot.
- If `price 0` (free), we return components with `present? == true`, amount 0 and the configured default currency symbol.
- If only `price_string` is set (e.g., "Contact us"), components return `present? == false`, `label == price_string`.

## Pure-data view models

- Per‑plan:

```ruby
plan.to_view_model
# => {
#   id:, key:, name:, description:, features:, highlighted:, default:, free:,
#   currency:, monthly_price_cents:, yearly_price_cents:,
#   monthly_price_id:, yearly_price_id:,
#   price_label:, price_string:, limits: { ... },
#   billing_intervals: [:month, :quarter, :year],
#   interval_prices: {
#     quarter: { amount_cents: 5400, monthly_equivalent_cents: 1800, label: "$54/qtr",
#                monthly_equivalent_label: "$18/mo", price_id: "price_pro_q" }, ...
#   }
# }
```

- All plans (preserves `PricingPlans.plans` order):

```ruby
PricingPlans.view_models # => Array<Hash>
```

## UI helpers

We include data‑only helpers into ActionView.

```ruby
pricing_plan_ui_data(plan)
# => {
#   monthly_price:, yearly_price:,
#   monthly_price_cents:, yearly_price_cents:,
#   monthly_price_id:, yearly_price_id:,
#   free:, label:
# }

pricing_plan_cta(plan, plan_owner: nil, context: :marketing, current_plan: nil, interval: :month)
# => { text:, url:, method: :get, disabled:, reason: }
```

`interval:` is passed to your `subscribe_path(plan:, interval:)`, same as `plan.cta_url(interval: :quarter)`.

`pricing_plan_cta` disables the button for the current plan (text: "Current Plan"). You can add a downgrade policy (see configuration) to surface `reason` in your UI.

## Plan comparison ergonomics (for CTAs)

```ruby
plan.current_for?(current_plan)      # boolean
plan.upgrade_from?(current_plan)     # boolean
plan.downgrade_from?(current_plan)   # boolean
plan.downgrade_blocked_reason(from: current_plan, plan_owner: org) # string | nil
```

Comparisons use the monthly price: the declared (or Stripe) monthly amount, else the cheapest per-month equivalent of the plan's intervals. A paid plan with only a `stripe_price` whose Stripe lookup fails compares as $0; `pricing_plans` logs a one-time warning naming it. Declare `price` next to `stripe_price` to compare without calling Stripe.

## Stripe lookups and caching

- We fetch Stripe Price objects when `stripe_price` is present.
- Caching is supported via `config.price_cache` (defaults to `Rails.cache` when available).
- TTL controlled by `config.price_cache_ttl` (default 10 minutes).

Example initializer snippet:

```ruby
PricingPlans.configure do |config|
  config.price_cache = Rails.cache
  config.price_cache_ttl = 10.minutes
end
```

## Configuration for pricing semantics

```ruby
PricingPlans.configure do |config|
  # Currency symbol when Stripe is absent
  config.default_currency_symbol = "$"

  # Cache & TTL for Stripe Price lookups
  config.price_cache = Rails.cache
  config.price_cache_ttl = 10.minutes

  # Optional hook to fully customize components
  # Signature: ->(plan, interval) { PricingPlans::PriceComponents | nil }
  config.price_components_resolver = ->(plan, interval) { nil }

  # Optional free copy used by some data helpers
  config.free_price_caption = "Forever free"

  # Default UI interval for toggles
  config.interval_default_for_ui = :month # or :year

  # Downgrade policy used by CTA ergonomics
  # Signature: ->(from:, to:, plan_owner:) { [allowed_boolean, reason_or_nil] }
  config.downgrade_policy = ->(from:, to:, plan_owner:) { [true, nil] }
end
```

## Stripe price labels in `plan.price_label`

By default, if a plan has `stripe_price` configured and the `stripe` gem is present, we auto-fetch the Stripe Price and render a friendly label (e.g., `$29/mo`). This mirrors Pay’s use of Stripe Prices.

Declaring a numeric `price` next to `stripe_price` opts that plan out: the local number is rendered and no Stripe call is made.


To disable auto-fetching globally:

```ruby
PricingPlans.configure do |config|
  config.auto_price_labels_from_processor = false
end
```

To fully customize rendering (e.g., caching, locale):

```ruby
PricingPlans.configure do |config|
  config.price_label_resolver = ->(plan) do
    # Build and return a string like "$29/mo" based on your own logic
  end
end
```