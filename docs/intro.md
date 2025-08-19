### Some features

Enforcing pricing plans is one of those boring plumbing problems that look easy from a distance but get complex when you try to engineer them for production usage. The poor man's implementation of nested ifs shown in the example above only get you so far, you soon start finding edge cases to consider. Here's some of what we've covered in this gem:

- Safe under load: we use row locks and retries when setting grace/blocked/warning state, and we avoid firing the same event twice. See [grace_manager.rb](lib/pricing_plans/grace_manager.rb).

- Accurate counting: persistent limits count live current rows (using `COUNT(*)`, make sure to index your foreign keys to make it fast at scale); per‑period limits record usage for the current window only. You can filter what counts with `count_scope` (Symbol/Hash/Proc/Array), and plan settings override model defaults. See [limitable.rb](lib/pricing_plans/limitable.rb) and [limit_checker.rb](lib/pricing_plans/limit_checker.rb).

- Clear rules: default is to block when you hit the cap; grace periods are opt‑in. In status/UI, 0 of 0 isn’t shown as blocked. See [plan.rb](lib/pricing_plans/plan.rb), [grace_manager.rb](lib/pricing_plans/grace_manager.rb), and [view_helpers.rb](lib/pricing_plans/view_helpers.rb).

- Simple controllers: one‑liners to guard actions, predictable redirect order (per‑call → per‑controller → global → pricing_path), and an optional central handler. See [controller_guards.rb](lib/pricing_plans/controller_guards.rb).

- Billing‑aware periods: supports billing cycle (when Pay is present), calendar month/week/day, custom time windows, and durations. See [period_calculator.rb](lib/pricing_plans/period_calculator.rb).


## Usage: available methods & full API reference

Assuming you've correctly installed the gem and configured your pricing plans in `pricing_plans.rb`, here's everything you can do:

### Downgrades and overages

When a customer moves to a lower plan (via Stripe/Pay or manual assignment), the new plan’s limits start applying immediately. Existing resources are never auto‑deleted by the gem; instead:

- **Persistent caps** (e.g., `:projects, to: 3`): We count live rows. If the account is now over the new cap, creations will be blocked (or put into grace/warn depending on `after_limit`). Users must remediate by deleting/archiving until under cap.
- **Per‑period allowances** (e.g., `:custom_models, to: 3, per: :month`): The current window’s usage remains as is. Further creations in the same window respect the downgraded allowance and `after_limit` policy. At the next window, the allowance resets.

Use `OverageReporter` to present a clear remediation UX before or after applying a downgrade:

```ruby
report = PricingPlans::OverageReporter.report_with_message(org, :free)
if report.items.any?
  flash[:alert] = report.message
  # report.items -> [#<OverageItem limit_key:, kind: :persistent|:per_period, current_usage:, allowed:, overage:, grace_active:, grace_ends_at:>]
end
```

Example human message:
- "Over target plan on: projects: 12 > 3 (reduce by 9), custom_models: 5 > 0 (reduce by 5). Grace active — projects grace ends at 2025-01-06T12:00:00Z."

Notes:
- If you provide a `config.message_builder`, it’s used to customize copy for the `:overage_report` context.
- This reporter works regardless of whether any controller/model action has been hit; it reads live counts and current period usage.

#### Override checks

Some times you'll want to override plan limits / feature gating checks. A common use case is if you're responding to a webhook (like Stripe), you'll want to process the webhook correctly (bypassing the check) and maybe later handle the limit manually.

To do that, you can use `require_plan_limit!`. An example to proceed but mark downstream:

```ruby
def webhook_create
  result = require_plan_limit!(:projects, billable: current_organization, allow_system_override: true)

  # Your custom logic here.
  # You could proceed to create; inspect result.grace?/warning? and result.metadata[:system_override]
  Project.create!(metadata: { created_during_grace: result.grace? || result.warning?, system_override: result.metadata[:system_override] })

  head :ok
end
```

Note: model validations will still block creation even with `allow_system_override` -- it's just intended to bypass the block on controllers.

### Semantic pricing API

Building delightful pricing UIs usually needs structured price parts (currency, amount, interval) and both monthly/yearly data. `pricing_plans` ships a semantic, UI‑agnostic API so you never parse strings in your app.

#### Value object: `PricingPlans::PriceComponents`

Structure returned by the helpers below. Pure data, no HTML:

```ruby
PricingPlans::PriceComponents = Struct.new(
  :present?,                 # boolean: price is numeric?
  :currency,                 # string currency symbol, e.g. "$", "€"
  :amount,                   # string whole amount, e.g. "29"
  :amount_cents,             # integer cents, e.g. 2900
  :interval,                 # :month | :year
  :label,                    # friendly label, e.g. "$29/mo" or "Contact"
  :monthly_equivalent_cents, # integer; = amount for monthly, or yearly/12 rounded
  keyword_init: true
)
```

#### Plan helpers (semantic pricing)

```ruby
plan.price_components(interval: :month)    # => PriceComponents
plan.monthly_price_components              # sugar for :month
plan.yearly_price_components               # sugar for :year

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

- If `stripe_price` is configured, we derive cents, currency, and interval from the Stripe Price (and cache it).
- If `price 0` (free), we return components with `present? == true`, amount 0 and the configured default currency symbol.
- If only `price_string` is set (e.g., "Contact us"), components return `present? == false`, `label == price_string`.

#### Pure-data view models

- Per‑plan:

```ruby
plan.to_view_model
# => {
#   id:, key:, name:, description:, features:, highlighted:, default:, free:,
#   currency:, monthly_price_cents:, yearly_price_cents:,
#   monthly_price_id:, yearly_price_id:,
#   price_label:, price_string:, limits: { ... }
# }
```

- All plans (preserves `PricingPlans.plans` order):

```ruby
PricingPlans.view_models # => Array<Hash>
```

#### UI helpers (pure data; no HTML opinions)

We include data‑only helpers into ActionView.

```ruby
pricing_plan_ui_data(plan)
# => {
#   monthly_price:, yearly_price:,
#   monthly_price_cents:, yearly_price_cents:,
#   monthly_price_id:, yearly_price_id:,
#   free:, label:
# }

pricing_plan_cta(plan, billable: nil, context: :marketing, current_plan: nil)
# => { text:, url:, method: :get, disabled:, reason: }
```

`pricing_plan_cta` disables the button for the current plan (text: "Current Plan"). You can add a downgrade policy (see configuration) to surface `reason` in your UI.

#### Plan comparison ergonomics (for CTAs)

```ruby
plan.current_for?(current_plan)      # boolean
plan.upgrade_from?(current_plan)     # boolean
plan.downgrade_from?(current_plan)   # boolean
plan.downgrade_blocked_reason(from: current_plan, billable: org) # string | nil
```

#### Stripe lookups and caching

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

#### Configuration for pricing semantics

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
  # Signature: ->(from:, to:, billable:) { [allowed_boolean, reason_or_nil] }
  config.downgrade_policy = ->(from:, to:, billable:) { [true, nil] }
end
```

#### Stripe price labels in `plan.price_label`

By default, if a plan has `stripe_price` configured and the `stripe` gem is present, we auto-fetch the Stripe Price and render a friendly label (e.g., `$29/mo`).

- This mirrors Pay’s use of Stripe Prices.
- To disable auto-fetching globally:

```ruby
PricingPlans.configure do |config|
  config.auto_price_labels_from_processor = false
end
```

- To fully customize rendering (e.g., caching, locale):

```ruby
PricingPlans.configure do |config|
  config.price_label_resolver = ->(plan) do
    # Build and return a string like "$29/mo" based on your own logic
  end
end
```

## Using with `pay` and/or `usage_credits`

`pricing_plans` is designed to work seamlessly with other complementary popular gems like `pay` (to handle actual subscriptions and payments), and `usage_credits` (to handle credit-like spending and refills)

These gems are related but not overlapping. They're complementary. The boundaries are clear: billing is handled in Pay; metering (ledger-like) in usage_credits.

The integration with `pay` should be seamless and is documented throughout this entire README; however, here's a brief note about using `usage_credits` alongside `pricing_plans`.

### Using `pricing_plans` with the `usage_credits` gem

In the SaaS world, pricing plans and usage credits are related in so far credits are usually a part of a pricing plan. A plan would give you, say, 100 credits a month along other features, and users would find that information usually documented in the pricing table itself.

However, for the purposes of this gem, pricing plans and usage credits are two very distinct things.

If you want to add credits to your app, you should install and configure the [usage_credits](https://github.com/rameerez/usage_credits) gem separately. In the `usage_credits` configuration, you should specify how many credits your users get with each subscription.

#### The difference between usage credits and per-period plan limits

> [!WARNING]
> Usage credits are not the same as per-period limits.

**Usage credits behave like a currency**. Per-period limits are not a currency, and shouldn't be purchaseable.

- **Usage credits** are like: "100 image-generation credits a month"
- **Per-period limits** are like: "Create up to 3 new projects a month"

Usage credits can be refilled (buy credit packs, your balance goes up), can be spent (your balance goes down). Per-period limits do not. If you intend to sell credit packs, or if the balance needs to go both up and down, you should implement usage credits, NOT per-period limits.

Some other examples of per-period limits: “1 domain change per week”, “2 exports/day”. Those are discrete allowances, not metered workloads. For classic metered workloads (API calls, image generations, tokenized compute), use credits instead.

Here's a few rules for a clean separation to help you decide when to use either gem:

`pricing_plans` handles:
  - Booleans (feature flags).
  - Persistent caps (max concurrent resources: products, seats, projects at a time).
  - Discrete per-period allowances (e.g., “3 exports / month”), with no overage purchasing.

`usage_credits` handles:
  - Metered consumption (API calls, generations, storage GB*hrs, etc.).
  - Included monthly credits via subscription plans.
  - Top-ups and pay-as-you-go.
  - Rollover/expire semantics and the entire ledger.

If a dimension is metered and you want to sell overage/top-ups, use credits only. Don’t also define a periodic limit for the same dimension in `pricing_plans`. We’ll actively lint and refuse dual definitions at boot.

#### How to show `usage_credits` in `pricing_plans`

With all that being said, in SaaS users would typically find information about plan credits in the pricing plan table, and because of that, and since `pricing_plans` should be the single source of truth for pricing plans in your Rails app, you should include how many credits your plans give in `pricing_plans.rb`:

```ruby
PricingPlans.configure do |config|
  plan :pro do
    bullets "API access", "100 credits per month"
  end
end
```

`pricing_plans` ships some ergonomics to declare and render included credits, and guardrails to keep your configuration coherent when `usage_credits` is present.

##### Declare included credits in your plans (single currency)

Plans can advertise the total credits included. This is cosmetic for pricing UI; `usage_credits` remains the source of truth for fulfillment and spending:

```ruby
PricingPlans.configure do |config|
  config.plan :free do
    price 0
    includes_credits 100
  end

  config.plan :pro do
    price 29
    includes_credits 5_000
  end
end
```

When you’re composing your UI, you can read credits via `plan.credits_included`.

> [!IMPORTANT]
> You need to keep defining operations and subscription fulfillment in your `usage_credits` initializer, declaring it in pricing_plans is purely cosmetic and for ergonomics to render pricing tables.

##### Guardrails when `usage_credits` is installed

When the `usage_credits` gem is present, we lint your configuration at boot to prevent ambiguous setups:

Collisions between credits and per‑period plan limits are disallowed: you cannot define a per‑period limit for a key that is also a `usage_credits` operation (e.g., `limits :api_calls, to: 50, per: :month`). If a dimension is metered, use credits only.

This enforces a clean separation:

- Use `usage_credits` for metered workloads you may wish to top‑up or charge PAYG for.
- Use `pricing_plans` limits for discrete allowances and feature flags (things that don’t behave like a currency).

##### No runtime coupling; single source of truth

`pricing_plans` does not spend or refill credits — that’s owned by `usage_credits`.

- Keep using `@user.spend_credits_on(:operation, ...)`, subscription fulfillment, and credit packs in `usage_credits`.
- Treat `includes_credits` here as pricing UI copy only. The single source of truth for operations, costs, fulfillment cadence, rollover/expire, and balances lives in `usage_credits`.
