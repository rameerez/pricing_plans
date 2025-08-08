# 💵 pricing_plans — Plans, features, limits, and grace that read like English

[![Gem Version](https://badge.fury.io/rb/pricing_plans.svg)](https://badge.fury.io/rb/pricing_plans)

`pricing_plans` is your plan catalog + enforcement brain for Rails.

- One Ruby file defines your plans, features, limits, and events.
- Plain-English guards for controllers and models.
- Real-time counts (no counter caches), race-safe grace, and friendly messages.

Perfect for Rails apps using Stripe via Pay, and optionally interoperating with `usage_credits` for metered workloads.

## Quickstart

Add to your Gemfile:

```ruby
gem "pricing_plans"
```

Then generate and migrate:

```bash
bundle install
rails generate pricing_plans:install
rails db:migrate
```

Define your catalog in `config/initializers/pricing_plans.rb`:

```ruby
PricingPlans.configure do |config|
  config.billable_class   = "Organization"
  config.default_plan     = :free
  config.highlighted_plan = :pro
  config.period_cycle     = :billing_cycle

  plan :free do
    name        "Free"
    description "Enough to launch and get your first real users!"
    price       0
    bullets     "25 end users", "1 product", "Community support"

    limits  :products, to: 1, after_limit: :grace_then_block, grace: 10.days, warn_at: [0.6, 0.8, 0.95]
    disallows :api_access, :flux_hd_access
  end

  plan :pro do
    stripe_price "price_pro_29"
    bullets "Flux HD", "3 custom models/month", "1,000 image credits/month"

    includes_credits 1_000, for: :generate_image
    limits :custom_models, to: 3, per: :month, after_limit: :grace_then_block, grace: 7.days
    allows :api_access, :flux_hd_access
  end

  plan :enterprise do
    price_string "Contact"
    description  "Get in touch and we'll fit your needs."
    bullets      "Custom limits", "Dedicated SLAs", "Dedicated support"

    unlimited :products
    allows    :api_access, :flux_hd_access
    meta      support_tier: "dedicated"
  end

  # Optional events: you decide the side effects
  config.on_warning     :products  { |org, threshold| PlanMailer.quota_warning(org, :products, threshold).deliver_later }
  config.on_grace_start :products  { |org, ends_at|   PlanMailer.grace_started(org, :products, ends_at).deliver_later  }
  config.on_block       :products  { |org|            PlanMailer.blocked(org, :products).deliver_later                 }
end
```

Models — limit with English:

```ruby
class Product < ApplicationRecord
  belongs_to :organization
  include PricingPlans::Limitable
  limited_by_pricing_plans :products, billable: :organization     # persistent cap
end

class CustomModel < ApplicationRecord
  belongs_to :organization
  include PricingPlans::Limitable
  limited_by_pricing_plans :custom_models, billable: :organization, per: :month  # discrete per-period
end
```

Controllers — English guards that “just work”:

```ruby
class ApiController < ApplicationController
  # Enforces a boolean feature. Also available: enforce_<feature_key>!(billable: ...)
  before_action :enforce_api_access!

  # Configure how to resolve the billable (optional)
  self.pricing_plans_billable_method = :current_organization
  # or
  # pricing_plans_billable { current_account }
end

class CustomModelsController < ApplicationController
  def create
    result = require_plan_limit! :custom_models, billable: current_organization
    return redirect_to(pricing_path, alert: result.message) if result.blocked?
    flash[:warning] = result.message if result.warning?
    # proceed to create
  end
end
```

Views — drop-in helpers:

```erb
<%= plan_limit_banner :products, billable: current_organization %>
<%= plan_usage_meter  :custom_models, billable: current_organization %>
<%= plan_pricing_table highlight: true %>
```

## What you define

- Plans: `name`, `description`, `bullets`, `meta`, and one of `price`, `price_string`, or `stripe_price`.
- Features: `allows :api_access` (plural and singular aliases supported).
- Limits:
  - Persistent caps (max concurrent): `limits :projects, to: 5`.
  - Discrete per-period allowances: `limits :custom_models, to: 3, per: :month`.
  - Behavior via `after_limit:`: `:grace_then_block` (default), `:block_usage`, `:just_warn`.
  - Grace via `grace:` (applies to the first two behaviors). Default: 7 days.
  - Warnings via `warn_at: [0.6, 0.8, 0.95]` (once per threshold per window).
- Credits (UI hint only): `includes_credits 1_000, for: :generate_image`.

## Controller ergonomics

- Dynamic feature guards: `enforce_<feature_key>!` resolves the billable and raises `PricingPlans::FeatureDenied` with a friendly upgrade message if disallowed.
- Limit guard: `require_plan_limit!(limit_key, billable:, by: 1)` returns a `Result` object with:
  - `ok?`, `warning?`, `grace?`, `blocked?`
  - `state` in `:within | :grace | :blocked`
  - `message` human with clear CTA
- Billable resolution:
  - Configure: `self.pricing_plans_billable_method = :current_organization` or `pricing_plans_billable { current_account }`.
  - If not configured, it tries: `current_<billable_class>` then common conventions (`current_organization`, `current_account`, `current_user`, ...).

## Model ergonomics

Include `PricingPlans::Limitable` and declare limits with the macro that reads like English:

```ruby
limited_by_pricing_plans :projects, billable: :organization
limited_by_pricing_plans :custom_models, billable: :organization, per: :month
```

- If you omit the key, it infers it from the table/collection name.
- If you omit the billable, it infers from `billable_class` or common associations, falling back to `:self`.
- Persistent caps count live rows. Per-period allowances increment a usage row per window.

## Interop

### Pay (Stripe)

We only read Pay; we never wrap or modify Pay’s API or models.

- What we read on your billable:
  - `subscribed?`, `on_trial?`, `on_grace_period?`
  - `subscription` (single) and `subscriptions` (collection)
  - `subscription.processor_plan` (e.g., Stripe price id)
  - `subscription.current_period_start` / `current_period_end` (billing anchors)

- What we don’t do:
  - We don’t include concerns into your models (no `pay_customer` setup on our side).
  - We don’t create, mutate, or sync Pay records.
  - We don’t add routes, jobs, or webhooks for Pay.

Plan resolution and billing windows leverage Pay state directly:

```ruby
# Plan resolution (conceptually)
if billable.subscribed? || billable.on_trial? || billable.on_grace_period?
  plan_key = billable.subscription&.processor_plan || billable.subscriptions&.find(&:active?)&.processor_plan
  # map processor_plan (e.g., Stripe price id) to your configured plan key
else
  # fall back to manual assignment or default
end

# Billing-cycle windows (conceptually)
if (sub = billable.subscription) && sub.respond_to?(:current_period_start) && sub.respond_to?(:current_period_end)
  window = [sub.current_period_start, sub.current_period_end]
else
  # fall back to calendar windows according to config
end
```

Downgrades via Stripe/Pay portal are not blocked at the billing layer: if the new plan is ineligible, we still switch, and then block violating actions in-app with clear upgrade CTAs. This matches Pay’s philosophy and avoids fragile cross-system coupling.

For official Pay docs, see `.docs/gems/pay.md` in this repo.

### usage_credits (optional)

Use its API directly for metered workloads (`spend_credits_on`, etc.). We only read the registry to render pricing lines and lint collisions. If you define both `includes_credits` and a per-period `limits` for the same key, we raise at boot.

## Events

- `on_warning :limit_key { |billable, threshold| ... }`
- `on_grace_start :limit_key { |billable, ends_at| ... }`
- `on_block :limit_key { |billable| ... }`

Fire once per threshold per window, and once at grace start/block. You own the side effects (email, Slack, etc.).

## Views

- `plan_limit_banner(limit_key, billable:)` — shows warnings/grace/block banners.
- `plan_usage_meter(limit_key, billable:)` — simple usage bar.
- `plan_pricing_table(highlight: true)` — Tailwind-friendly pricing table scaffolding.
- Utilities: `current_plan_name(billable)`, `plan_allows?(billable, :feature)`, `plan_limit_remaining(billable, :key)`, `plan_limit_percent_used(billable, :key)`.

## Generators

- `rails g pricing_plans:install` — migrations + initializer scaffold.
- `rails g pricing_plans:pricing` — pricing controller + partials + CSS.
- `rails g pricing_plans:mailers` — mailer stubs (optional).

## Schema

- `pricing_plans_enforcement_states` — per-billable per-limit grace state.
- `pricing_plans_usages` — per-window counters for discrete allowances.
- `pricing_plans_assignments` — manual plan overrides.

## Performance & correctness

- Live DB counting for persistent caps; no counter caches.
- Row-level locks for grace state; retries on deadlocks.
- Efficient upserts for per-period usage (PG) or transaction fallback.

## Testing

The gem ships with comprehensive Minitest coverage for plans, registry, plan resolution, limit checking, grace manager, model mixins, controller guards, dynamic callbacks, and view helpers. We test grace semantics, thresholds, concurrency/idempotency, and edge cases.

## License

MIT
