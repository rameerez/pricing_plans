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

    limits  :products, to: 1.max, after_limit: :block_usage
    disallows :api_access, :flux_hd_access
  end

  plan :pro do
    stripe_price "price_pro_29"
    bullets "Flux HD", "3 custom models/month", "1,000 image credits/month"

    includes_credits 1_000, for: :generate_image
    limits :custom_models, to: 3, per: :month, after_limit: :grace_then_block, grace: 7.days, warn_at: [0.6, 0.8, 0.95]
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

Advanced associations (fully supported):

- Custom `class_name:` and `foreign_key:` on `has_many`.
- Namespaced child models (e.g., `class_name: "Deeply::NestedResource"`).
- Explicit `limit_key:` if you want a different key than the association name.

Child-side macro (optional):

```ruby
class Project < ApplicationRecord
  belongs_to :organization
  include PricingPlans::Limitable
  limited_by_pricing_plans :projects, on: :organization, error_after_limit: "Too many projects!"
end
```
We recommend the billable-centric style for the cleanest DX.

## Credits vs Limits — decision table

- Use `includes_credits` (via `usage_credits` gem) for metered events and overage models (increment-only, wallet-like semantics, with purchase/overage handling outside this gem).
- Use `limits` here when you want either:
  - Persistent caps: concurrent resource ceilings (e.g., projects, seats).
  - Discrete per-period allowances: rare monthly allowances that reset per billing window (e.g., “3 custom models per month”).

Rules enforced at boot:
- You cannot define both `includes_credits` and a per-period `limits` for the same key. This prevents double-metering.
- When `usage_credits` is present, `includes_credits` must point to a known operation, or boot will fail.

## Persistent vs Per-period (how the mixin behaves)

- Persistent caps
  - Counting is live: `SELECT COUNT(*)` scoped to the billable association, no counter caches.
  - Validation on create: blocks immediately on `:block_usage`, or blocks when grace is considered “blocked” on `:grace_then_block`. `:just_warn` passes.
  - Deletes automatically lower the count. Backfills simply reflect current rows.

- Per-period allowances
  - Increments a usage row on create for the current window (no decrement on delete).
  - Window resets:
    - Default window is `:billing_cycle` if available from Pay; otherwise `:calendar_month` or your configured `period_cycle`.
    - Enforcement state (grace/warnings) is per window; we reset it at boundaries.
  - Concurrency: insert/upsert is resilient (RecordNotUnique fallback).

Gotchas and tips
- Deleting rows under persistent caps reduces usage immediately — no extra work needed.
- For per-period, avoid deleting to “refund” usage: usage is increment-only by design.
- Multi-tenant scoping: ensure your associations reflect the billable boundary (e.g., `belongs_to :organization`).
- Timezones: we use `Time.current` and Pay billing anchors when available; calendar windows follow Rails time zone.

## Billable-centric API (reads like English)

The configured billable class (e.g., `Organization`) automatically gains these helpers:

```ruby
org.within_plan_limits?(:projects, by: 1)        # => true/false
org.plan_limit_remaining(:projects)              # => integer or :unlimited
org.plan_limit_percent_used(:projects)           # => Float percent
org.remaining(:projects)                         # alias of plan_limit_remaining
org.percent_used(:projects)                      # alias of plan_limit_percent_used
# English-y sugar (generated from has_many :<limit_key>)
org.projects_within_plan_limits?(by: 1)
org.projects_remaining
org.projects_percent_used
org.projects_grace_active?
org.projects_grace_ends_at
org.projects_blocked?
```

Naming patterns (auto-generated from `has_many :<limit_key>`):

- `<limit_key>_within_plan_limits?(by: 1)`
- `<limit_key>_remaining`
- `<limit_key>_percent_used`
- `<limit_key>_grace_active?`
- `<limit_key>_grace_ends_at`
- `<limit_key>_blocked?`
org.current_pricing_plan                         # => PricingPlans::Plan
org.assign_pricing_plan!(:pro)                   # manual assignment override
org.remove_pricing_plan!                         # remove manual override (fallback to default)

# Feature flags
org.plan_allows?(:api_access)                    # => true/false

# Pay (Stripe) convenience (returns false/nil when Pay is absent). Note: this is billing-facing state,
# distinct from our in-app enforcement grace which is tracked per-limit below.
org.pay_subscription_active?                     # => true/false
org.pay_on_trial?                                # => true/false
org.pay_on_grace_period?                         # => true/false

# Grace helpers (per limit key, managed by PricingPlans — in-app enforcement)
org.grace_active_for?(:projects)                 # => true/false
org.grace_ends_at_for(:projects)                 # => Time or nil
org.grace_remaining_seconds_for(:projects)       # => Integer seconds
org.grace_remaining_days_for(:projects)          # => Integer days (ceil)
org.plan_blocked_for?(:projects)                 # => true/false (considering after_limit policy)
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
<%# Current plan object %>
<%= current_pricing_plan(current_organization).name %>

<%# Admin visibility (read-only) %>
<%= render_plan_limit_status :projects, billable: current_organization %>
```

## Visibility helpers (admin-friendly)

- `plan_limit_status(limit_key, billable:)` returns a hash:
  - `configured`, `limit_key`, `limit_amount`, `current_usage`, `percent_used`, `grace_active`, `grace_ends_at`, `blocked`, `after_limit`, `per`.
- `render_plan_limit_status(limit_key, billable:)` renders a minimal status block (OK/GRACE/BLOCKED, usage, percent, grace timer). Tailwind-friendly classes:
  - Container: `pricing-plans-status is-ok|is-grace|is-blocked`.

## Downgrade overage flow (UX)

When a customer downgrades to a lower plan via Stripe/Pay portal, we accept the change and enforce in-app limits. To present clear remediation:

```ruby
report = PricingPlans::OverageReporter.report_with_message(org, :free)
if report.items.any?
  flash[:alert] = report.message
  # report.items is an array of OverageItem(limit_key:, kind:, current_usage:, allowed:, overage:, grace_active:, grace_ends_at:)
end
```

Example human message:
- "Over target plan on: projects: 12 > 3 (reduce by 9), custom_models: 5 > 0 (reduce by 5). Grace active — projects grace ends at 2025-01-06T12:00:00Z."

Display remediation inline with your resource index (e.g., list projects and let users archive/delete).

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

Plan resolution: Pay → manual assignment → default plan. Billing windows prefer Pay anchors when present; otherwise fallbacks follow your configured `period_cycle` (default `:billing_cycle`, fallback calendar month).

Downgrades via Stripe/Pay portal are not blocked at the billing layer: if the new plan is ineligible, we still switch, and then block violating actions in-app with clear upgrade CTAs. This matches Pay’s philosophy and avoids fragile cross-system coupling.

### usage_credits (optional)

Use its API directly for metered workloads (`spend_credits_on`, etc.). We only read the registry to render pricing lines and lint collisions. If you define both `includes_credits` and a per-period `limits` for the same key, we raise at boot. When `usage_credits` is present, `includes_credits` must reference a known operation; unknown operations raise during boot.

## Indexing & performance guidance

- We ship indexes for the internal tables:
  - `pricing_plans_enforcement_states`: unique (billable_type, billable_id, limit_key), partial index on `exceeded_at`.
  - `pricing_plans_usages`: unique (billable_type, billable_id, limit_key, period_start), plus billable and period indexes.
  - `pricing_plans_assignments`: unique (billable_type, billable_id) + index on `plan_key`.
- Add domain indexes to support persistent caps efficiently:
  - For `has_many :projects, ...`: add index on `projects.organization_id`.
  - For deeper associations, ensure foreign keys from the child to the billable are indexed.
- Avoid N+1 in your UI: fetch counts in bulk if needed, or render minimal components (`render_plan_limit_status`) that compute on demand.

## Events

- `on_warning :limit_key { |billable, threshold| ... }`
- `on_grace_start :limit_key { |billable, ends_at| ... }`
- `on_block :limit_key { |billable| ... }`

Fire once per threshold per window, and once at grace start/block. You own the side effects (email, Slack, etc.).

## Complex names and associations

We test and support:

- Custom `class_name:` and `foreign_key:` on `has_many`.
- Namespaced child classes (e.g., `Deeply::NestedResource`).
- Late definition of child classes (limits and sugar wire up when the constant resolves).
- Explicit `limit_key:` to decouple the key from the association name.

## Schema

- `pricing_plans_enforcement_states` — per-billable per-limit grace state.
- `pricing_plans_usages` — per-window counters for discrete allowances.
- `pricing_plans_assignments` — manual plan overrides.

## Performance & correctness

- Live DB counting for persistent caps; no counter caches.
- Row-level locks for grace state; retries on deadlocks.
- Efficient upserts for per-period usage (PG) or transaction fallback.
- Per-period enforcement state resets at window boundaries (warnings and grace are per-window).

## Testing

The gem ships with comprehensive Minitest coverage for plans, registry, plan resolution, limit checking, grace manager, model mixins, association-based DSL, controller guards (including `for:`), dynamic callbacks, view helpers, and visibility helpers. We test grace semantics, thresholds, concurrency/idempotency, complex associations, late binding, naming, Pay parity, window boundaries, and downgrade reporting.

## License

MIT
