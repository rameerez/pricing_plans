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
# Enable DSL sugar like `1.max` in this initializer (generator includes this line)
using PricingPlans::IntegerRefinements

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

    limits  :products, to: 1.max, after_limit: :grace_then_block, grace: 10.days, warn_at: [0.6, 0.8, 0.95]
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

## Models — limit with English (billable-centric)

Two kinds of limits:

- Persistent caps (max concurrent items): live DB count, no counters.
- Discrete per-period allowances: increments a usage row per billing window.

Syntactic sugar:

- Omit the limit key when it can be inferred from the model (e.g., `Project` → `:projects`).
- Use `on:` as an English alias for `billable:`.
- Customize the validation error message with `error_after_limit:`.

```ruby
class Organization < ApplicationRecord
  include PricingPlans::Billable

  # Persistent cap (key inferred from association name). English-y and Rails-y.
  has_many :projects, limited_by_pricing_plans: { error_after_limit: "Too many projects!" }, dependent: :destroy

  # Discrete per-period allowance (explicit limit key, per-period, custom message)
  has_many :custom_models,
    limited_by_pricing_plans: { limit_key: :custom_models, per: :month, error_after_limit: "Monthly cap" }
end
```

Behavior:

- Persistent caps count live rows (per billable). When over the cap:
  - `:just_warn` → validation passes; use controller guard to warn.
  - `:block_usage` → validation fails immediately (uses `error_after_limit` if set).
  - `:grace_then_block` → validation fails once grace is considered “blocked” (we track and switch from grace to blocked).
- Per-period allowances increment a usage record for the window; when over, behavior follows the same `after_limit` policy.
- Prefer declaring limits on the billable model. The child model wiring is injected automatically.

## Billable-centric API (reads like English)

The configured billable class (e.g., `Organization`) automatically gains these helpers:

```ruby
org.within_plan_limits?(:projects, by: 1)        # => true/false
org.plan_limit_remaining(:projects)              # => integer or :unlimited
org.plan_limit_percent_used(:projects)           # => Float percent
org.remaining(:projects)                         # alias of plan_limit_remaining
org.percent_used(:projects)                      # alias of plan_limit_percent_used
org.current_pricing_plan                         # => PricingPlans::Plan
org.assign_pricing_plan!(:pro)                   # manual assignment override
org.remove_pricing_plan!                         # remove manual override (fallback to default)
```

## Controllers — English guards that “just work”

We recommend defining a current billable helper in your `ApplicationController` (the gem also auto-tries common conventions):

```ruby
class ApplicationController < ActionController::Base
  # Adapt to your auth/session logic
  def current_organization
    # Your lookup here (e.g., current_user.organization)
  end
end
```

Feature guard (dynamic):

```ruby
class ApiController < ApplicationController
  # Enforces a boolean feature. Reads like English; no extra config line.
  before_action :enforce_api_access!, for: :current_organization
end
```

Limit guard (returns a Result with human message and state):

```ruby
class ProjectsController < ApplicationController
  def create
    org = current_organization
    result = PricingPlans::ControllerGuards.require_plan_limit!(:projects, billable: org, by: 1)
    return redirect_to(pricing_path, alert: result.message) if result.blocked?
    flash[:warning] = result.message if result.warning? || result.grace?
    Project.create!(organization: org, name: params[:name])
    redirect_to root_path, notice: "Created"
  end
end
```

Notes:

- The dynamic `enforce_<feature>!` guard also accepts `billable:` and a `for:` proc:
  ```ruby
  before_action { enforce_api_access!(for: -> { current_organization }) }
  # or explicitly
  before_action { enforce_api_access!(billable: current_organization) }
  ```
- The gem will try to infer a billable via:
  - `current_<billable_class>` (e.g., `current_organization`), then
  - common conventions: `current_organization`, `current_account`, `current_user`, `current_team`, `current_company`, `current_workspace`, `current_tenant`.

## Views — drop-in helpers

```erb
<%= plan_limit_banner :projects, billable: current_organization %>
<%= plan_usage_meter  :projects, billable: current_organization %>
<%= plan_pricing_table highlight: true %>

<!-- Utilities -->
<%= current_plan_name(current_organization) %>
<%= plan_allows?(current_organization, :api_access) %>
<%= plan_limit_remaining(current_organization, :projects) %>
<%= plan_limit_percent_used(current_organization, :projects) %>
<%# New: fetch current plan object %>
<%= current_pricing_plan(current_organization).name %>
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
  - Unlimited sugar: `unlimited :projects`.
  - UI credits (hint only): `includes_credits 1_000, for: :generate_image`.

## DSL ergonomics

- Configuration block supports both styles:
  ```ruby
  PricingPlans.configure do
    plan :free { ... }  # instance-eval DSL
  end

  PricingPlans.configure do |config|
    config.plan :free { ... }  # explicit config
  end
  ```
- In models:
  - Omit key when inferrable from the model/table name.
  - Use `on:` as an alias for `billable:`.
  - Provide `error_after_limit:` to customize model validation error on block.

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

Plan resolution and billing windows will prefer Pay when present, otherwise fall back to manual assignment or default plan and calendar windows per config.

### usage_credits (optional)

Use its API directly for metered workloads (`spend_credits_on`, etc.). We only read the registry to render pricing lines and lint collisions. If you define both `includes_credits` and a per-period `limits` for the same key, we raise at boot.

## Events

- `on_warning :limit_key { |billable, threshold| ... }`
- `on_grace_start :limit_key { |billable, ends_at| ... }`
- `on_block :limit_key { |billable| ... }`

Fire once per threshold per window, and once at grace start/block. You own the side effects (email, Slack, etc.).

## Generators

- `rails g pricing_plans:install` — migrations + initializer scaffold (includes the `using PricingPlans::IntegerRefinements` line).
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

The gem ships with comprehensive Minitest coverage for plans, registry, plan resolution, limit checking, grace manager, model mixins, controller guards (including `for:`), dynamic callbacks, and view helpers. We test grace semantics, thresholds, concurrency/idempotency, custom error messages, and edge cases.

## License

MIT
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
# Enable DSL sugar like `1.max` in this initializer
using PricingPlans::IntegerRefinements

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
