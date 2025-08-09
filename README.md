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
rails g pricing_plans:install
rails db:migrate
```

Define your catalog in `config/initializers/pricing_plans.rb`:

```ruby
# Enable DSL sugar like `1.max` in this initializer (generator includes this line)
using PricingPlans::IntegerRefinements

PricingPlans.configure do |config|
  # Optional: hint controller inference of billable (we also infer via common conventions)
  # config.billable_class   = "Organization"
  # Optional defaults; can also be set via DSL sugar within plans
  # config.default_plan     = :free
  # config.highlighted_plan = :pro
  # config.period_cycle     = :billing_cycle

  plan :free do
    name        "Free"
    description "Enough to launch and get your first real users!"
    price       0
    bullets     "25 end users", "1 product", "Community support"

    limits  :products, to: 1.max, after_limit: :block_usage
    disallows :api_access, :flux_hd_access
    default!
  end

  plan :pro do
    stripe_price "price_pro_29"
    bullets "Flux HD", "3 custom models/month", "1,000 image credits/month"
    # Optional CTA overrides for pricing UI (defaults provided)
    cta_text "Subscribe"
    # If using Pay, prefer using their helpers/routes for checkout. See the Pay docs link below.
    # cta_url  checkout_path # or a full URL if you’re handling checkout yourself

    includes_credits 1_000, for: :generate_image
    limits :custom_models, to: 3, per: :month, after_limit: :grace_then_block, grace: 7.days, warn_at: [0.6, 0.8, 0.95]
    allows :api_access, :flux_hd_access
    highlighted!
  end

  plan :enterprise do
    price_string "Contact"
    description  "Get in touch and we'll fit your needs."
    bullets      "Custom limits", "Dedicated SLAs", "Dedicated support"
    cta_text "Contact sales"
    cta_url  "mailto:sales@example.com"

    unlimited :products
    allows    :api_access, :flux_hd_access
    meta      support_tier: "dedicated"
  end

  # Optional events: you decide the side effects (parentheses required)
  config.on_warning(:products)     { |org, threshold| PlanMailer.quota_warning(org, :products, threshold).deliver_later }
  config.on_grace_start(:products) { |org, ends_at|   PlanMailer.grace_started(org, :products, ends_at).deliver_later  }
  config.on_block(:products)       { |org|            PlanMailer.blocked(org, :products).deliver_later                 }
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

  - Filtered counting via count_scope: scope persistent caps to active-only rows.
    - Idiomatic options:
      - Plan DSL with AR Hash: `limits :licenses, to: 25, count_scope: { status: 'active' }`
      - Plan DSL with named scope: `limits :activations, to: 50, count_scope: :active`
      - Plan DSL with multiple: `limits :seats, to: 10, count_scope: [:active, { kind: 'paid' }]`
      - Macro form: `has_many :licenses, limited_by_pricing_plans: { limit_key: :licenses, count_scope: :active }`
      - Full freedom: `->(rel) { rel.where(status: 'active') }` or `->(rel, org) { rel.where(organization_id: org.id) }`
    - Accepted types: Symbol (named scope), Hash (where), Proc (arity 1 or 2), or Array of these (applied left-to-right).
    - Precedence: plan-level `count_scope` overrides macro-level `count_scope`.
    - Restriction: `count_scope` only applies to persistent caps (not allowed on per-period limits).
    - Performance: add indexes for your filters (e.g., `status`, `deactivated_at`).

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

  # Aggregates across keys
  org.any_grace_active_for?(:products, :activations)
  org.earliest_grace_ends_at_for(:products, :activations)
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

Default behavior out of the box:

- Disallowed features raise `PricingPlans::FeatureDenied`.
- The engine maps this to HTTP 403 by default and installs a controller rescue that:
  - HTML/Turbo: redirects to `pricing_path` with an alert (303 See Other) if the helper exists; otherwise renders a 403 with the message.
  - JSON: returns `{ error: message }` with 403.

You can override the behavior by defining `handle_pricing_plans_feature_denied(error)` in your `ApplicationController`, or by adding your own `rescue_from PricingPlans::FeatureDenied`.

### Controller guards — API and options

We provide both dynamic, English-y helpers and lower-level primitives.

- Dynamic feature guard (before_action-friendly):
  - `enforce_<feature_key>!(on: :current_organization)` — raises `FeatureDenied` when disallowed (we rescue it for you by default).

- Dynamic limit guard (before_action-friendly):
  - `enforce_<limit_key>_limit!(on:, by: 1, redirect_to: nil, allow_system_override: false)`
    - Defaults: `by: 1` (omit for single-create). `on:` is a friendly alias for `billable:`.
    - When blocked: redirects to `redirect_to` if given, else to `pricing_path` if available; otherwise renders HTTP 403 (JSON/plain). Aborts the filter chain.
    - When grace/warning: sets `flash[:warning]` with a human message.
    - With `allow_system_override: true`: returns true (no redirect), letting you proceed; the Result carries `metadata[:system_override]` for downstream handling.

- Generic helpers and primitives:
  - `enforce_plan_limit!(limit_key, on: ..., by: 1, redirect_to: nil, allow_system_override: false)` — same behavior as the dynamic version.
  - `require_plan_limit!(limit_key, billable:, by: 1, allow_system_override: false)` — returns a `Result` (`within?/warning?/grace?/blocked?`) for manual handling.

Billable resolution options:
- `on: :current_organization` or `on: -> { find_org }` — alias of `billable:` for controllers.
- `billable:` — pass the instance directly.
- You can globally configure a resolver via `self.pricing_plans_billable_method = :current_organization` or `pricing_plans_billable { current_account }`.

Examples:

```ruby
class LicensesController < ApplicationController
  # English-y limit guard; by: defaults to 1
  before_action { enforce_licenses_limit!(on: :current_organization) }, only: :create

  def create
    License.create!(organization: current_organization, ...)
    redirect_to licenses_path, notice: "Created"
  end
end
```

Inline usage (custom redirect target):

```ruby
def create
  enforce_plan_limit!(:products, on: :current_organization, redirect_to: pricing_path)
  Product.create!(organization: current_organization, ...)
  redirect_to products_path
end
```

Bulk actions (set by:) — e.g. importing 5 at once:

```ruby
def import
  enforce_products_limit!(on: :current_organization, by: 5)
  ProductImporter.import!(current_organization, rows)
  redirect_to products_path
end
```

Trusted flows (system override) — proceed but mark downstream:

```ruby
def webhook_create
  result = require_plan_limit!(:licenses, billable: current_organization, allow_system_override: true)
  # Proceed to create; inspect result.grace?/warning? and result.metadata[:system_override]
  License.create!(organization: current_organization, metadata: { created_during_grace: result.grace? || result.warning?, system_override: result.metadata[:system_override] })
  head :ok
end
```

Feature guard (dynamic):

```ruby
class ApiController < ApplicationController
  # Enforces a boolean feature. Reads like English; no extra config line.
  before_action { enforce_api_access!(on: :current_organization) }
end
```

Limit guard (English-y, redirect/flash handled for you; use as a before_action or inline):

```ruby
class ProjectsController < ApplicationController
  # Defaults by: 1, so you can omit it; on: is an English alias for billable:
  before_action { enforce_projects_limit!(on: :current_organization) }

  def create
    Project.create!(organization: current_organization, name: params[:name])
    redirect_to root_path, notice: "Created"
  end
end
```

Inline usage:

```ruby
enforce_projects_limit!(on: :current_organization, redirect_to: pricing_path)
```
Trusted system overrides (webhooks/jobs):

```ruby
result = PricingPlans::ControllerGuards.require_plan_limit!(
  :licenses,
  billable: org,
  by: 1,
  allow_system_override: true
)
if result.blocked? && result.metadata[:system_override]
  # Proceed to create but mark for review/cleanup; you decide semantics here
end
```

Notes:

- The dynamic `enforce_<feature>!` guard also accepts `billable:` and a `for:` proc:
  ```ruby
  before_action { enforce_api_access!(for: -> { current_organization }) }
  # or explicitly
  before_action { enforce_api_access!(billable: current_organization) }
  ```
- The gem will try to infer a billable via common conventions: `current_organization`, `current_account`, `current_user`, `current_team`, `current_company`, `current_workspace`, `current_tenant`. If you set `billable_class`, we’ll also try `current_<billable_class>`.

Override the default 403 handler (optional):

```ruby
class ApplicationController < ActionController::Base
  private
  def handle_pricing_plans_feature_denied(error)
    # Custom HTML handling
    redirect_to upgrade_path, alert: error.message, status: :see_other
  end
end
```

## Jobs — ergonomic guard for trusted flows

Background workers often need to proceed while still signaling over-limit state (e.g., webhooks). Use the job helper for concise semantics:

```ruby
# In any job/service
PricingPlans::JobGuards.with_plan_limit(
  :licenses,
  billable: org,
  by: 1,
  allow_system_override: true
) do |result|
  # Perform the work; result carries human state
  # result.ok?/warning?/grace?/blocked?
  # result.metadata[:system_override] is set when we’re over the limit but allowed to proceed

  LicenseIssuer.issue!(
    plan_key: mapping.license_plan.key,
    product: mapping.license_plan.product,
    tenant: org,
    owner: customer,
    metadata: { created_during_grace: result.grace? || result.warning? }
  )
end
```

- Yields only when within limit, or when `allow_system_override: true`.
- Always returns the `Result` object so you can branch even without a block.
- Use sparingly; UI paths should use controller helpers that redirect/flash on block.

## Views — drop-in helpers

```erb
<%= plan_limit_banner :projects, billable: current_organization %>
<%= plan_usage_meter  :projects, billable: current_organization %>
<%= plan_pricing_table highlight: true %>
```

### Composite usage widget (2–3 limits panel)

If you generated the pricing UI into your app, `_usage_meter.html.erb` also supports a compact, multi-limit block when given locals:

```erb
<%= render partial: "pricing_plans/usage_meter",
           locals: { limits: [:products, :licenses, :activations], billable: current_organization } %>
```

It renders per-limit labels and bars using your plan configuration and live counts.

### CTA and Pay (Stripe/Paddle/etc.)

When a plan has a `stripe_price`, the default `cta_text` becomes "Subscribe" and the default `cta_url` is nil. We intentionally do not hardwire Pay integration in the gem views because the host app controls processor, routes, and checkout UI. You have two simple options:

- Use your own controller action to start checkout and set `cta_url` to that path. Inside the action, call your Pay integration (e.g., Stripe Checkout, Billing Portal, or Paddle). See the official Pay docs (bundled here as `docs/pay.md`) for the exact APIs.
- Override the pricing partial `_plan_card.html.erb` to attach your desired data attributes for Pay’s JavaScript integrations (e.g., Paddle.js, Lemon.js) or link to a Checkout URL.

Recommended baseline for Stripe via Pay:

1) Create an action that sets the processor and creates a Checkout Session.

```ruby
class SubscriptionsController < ApplicationController
  def checkout
    current_user.set_payment_processor :stripe
    checkout = current_user.payment_processor.checkout(
      mode: "subscription",
      line_items: [{ price: "price_pro_29" }],
      success_url: root_url,
      cancel_url: root_url
    )
    redirect_to checkout.url, allow_other_host: true, status: :see_other
  end
end
```

2) Point your plan’s `cta_url` to that controller route or override the partial to link it. Alternatively, opt-in to an automatic CTA URL generator:

```ruby
# config/initializers/pricing_plans.rb
PricingPlans.configure do |config|
  # Global generator (optional). Arity can be (billable, plan, view) | (billable, plan) | (billable)
  config.auto_cta_with_pay = ->(billable, plan, view) do
    billable.set_payment_processor :stripe unless billable.respond_to?(:payment_processor) && billable.payment_processor
    price_id = plan.stripe_price.is_a?(Hash) ? (plan.stripe_price[:id] || plan.stripe_price.values.first) : plan.stripe_price
    session = billable.payment_processor.checkout(
      mode: "subscription",
      line_items: [{ price: price_id }],
      success_url: view.root_url,
      cancel_url: view.root_url
    )
    session.url
  end
end
```

Or per-view usage:

```erb
<% # In a view: %>
<% generator = ->(billable, plan, view) { billable.set_payment_processor(:stripe); billable.payment_processor.checkout(mode: "subscription", line_items: [{ price: plan.stripe_price[:id] || plan.stripe_price }], success_url: view.root_url, cancel_url: view.root_url).url } %>
<%= link_to plan.cta_text, pricing_plans_auto_cta_url(plan, current_user, generator) || "#" %>
```

Notes:
- Pay requires you to install and configure it (customers, credentials, webhooks). See `docs/pay.md` included in this repo for the full, official setup.
- Paddle Billing and Lemon Squeezy use JS overlays/hosted pages; the approach is similar: wire a route that prepares any server state, then link or add the data attributes in the CTA.

### Ultra-fast Pay quickstart (optional)

We ship an example method (commented) in the generated `PricingController` that you can enable to make CTAs work immediately:

```ruby
# app/controllers/pricing_controller.rb
# def subscribe
#   plan_key = params[:plan]&.to_sym
#   plan = PricingPlans.registry.plan(plan_key)
#   return redirect_to(pricing_path, alert: "Unknown plan") unless plan
#   return redirect_to(pricing_path, alert: "Plan not purchasable") unless plan.stripe_price
#
#   billable = respond_to?(:current_user) && current_user&.respond_to?(:organization) ? current_user.organization : current_user
#   return redirect_to(pricing_path, alert: "Sign in required") unless billable
#
#   billable.set_payment_processor :stripe unless billable.respond_to?(:payment_processor) && billable.payment_processor
#   price_id = plan.stripe_price.is_a?(Hash) ? (plan.stripe_price[:id] || plan.stripe_price.values.first) : plan.stripe_price
#   session = billable.payment_processor.checkout(
#     mode: "subscription",
#     line_items: [{ price: price_id }],
#     success_url: root_url,
#     cancel_url: pricing_url
#   )
#   redirect_to session.url, allow_other_host: true, status: :see_other
# end
```

Add a route, and you can set `plan.cta_url pricing_subscribe_path(plan: plan.key)` or keep using the auto generator:

```ruby
# config/routes.rb
post "pricing/subscribe", to: "pricing#subscribe", as: :pricing_subscribe
```

### Pay integration (what you need to do)

If you want Stripe/Paddle/Lemon Squeezy checkout to power your plan CTAs, install and configure the Pay gem in your app. At minimum:

1) Add the gems and run the Pay generators/migrations (see `docs/pay.md`).
2) Configure credentials and webhooks per Pay’s docs.
3) On your billable model, add `pay_customer` and ensure it responds to `email` (and optionally `name`).
4) Provide a controller action to start checkout (Stripe example above; Paddle/Lemon use overlay/hosted JS with data attributes).
5) Point CTA buttons to your action or override the pricing partial to embed the attributes.

We do not add any Pay routes or include concerns automatically; you stay in control.


<!-- Utilities -->
<%= current_plan_name(current_organization) %>
<%= plan_allows?(current_organization, :api_access) %>
<%= plan_limit_remaining(current_organization, :projects) %>
<%= plan_limit_percent_used(current_organization, :projects) %>
<%# Current plan object %>
<%= current_pricing_plan(current_organization).name %>

<%# Admin visibility (read-only) %>
<%= render_plan_limit_status :projects, billable: current_organization %>

Use its API directly for metered workloads (`spend_credits_on`, etc.). We only read the registry to render pricing lines and lint collisions. If you define both `includes_credits` and a per-period `limits` for the same key, we raise at boot. When `usage_credits` is present, `includes_credits` must reference a known operation; unknown operations raise during boot.

## Events

- `on_warning(:limit_key) { |billable, threshold| ... }`
- `on_grace_start(:limit_key) { |billable, ends_at| ... }`
- `on_block(:limit_key) { |billable| ... }`

Note: parentheses are required for event DSL methods.

Fire once per threshold per window, and once at grace start/block. You own the side effects (email, Slack, etc.).

## Generators

- `rails g pricing_plans:install` — migrations + initializer scaffold (includes the `using PricingPlans::IntegerRefinements` line).
- `rails g pricing_plans:pricing` — pricing controller + partials + CSS (includes a composite usage widget block).
- `rails g pricing_plans:mailers` — mailer stubs (optional).

## Complex names and associations

We test and support:

- Custom `class_name:` and `foreign_key:` on `has_many`.
- Namespaced child classes (e.g., `Deeply::NestedResource`).
- Late definition of child classes (limits and sugar wire up when the constant resolves).
- Explicit `limit_key:` to decouple the key from the association name.

## Schema — the three tables we create (what/why/how)

- `pricing_plans_enforcement_states` (model: `PricingPlans::EnforcementState`)
  - Why: Track per-billable per-limit enforcement state for persistent caps and per-period allowances (grace/warnings/block state) in a race-safe way.
  - What: `exceeded_at`, `blocked_at`, last warning info, and a small JSON `data` column where we persist plan-derived parameters like grace period seconds.
  - How it’s used: When you exceed a limit, we upsert/read this row under row-level locking to start grace, compute when it ends, flip to blocked, and to ensure idempotent event emission (`on_warning`, `on_grace_start`, `on_block`).

- `pricing_plans_usages` (model: `PricingPlans::Usage`)
  - Why: Track discrete per-period allowances (e.g., “3 custom models per month”). Persistent caps don’t need a table because they are live counts.
  - What: `period_start`, `period_end`, and a monotonic `used` counter with a last-used timestamp.
  - How it’s used: On create of the metered model, we increment or upsert the usage for the current window (based on `PeriodCalculator`). Reads power `remaining`, `percent_used`, and warning thresholds.

- `pricing_plans_assignments` (model: `PricingPlans::Assignment`)
  - Why: Allow manual plan overrides independent of billing system (or before you wire up Stripe/Pay). Great for admin toggles, trials, demos.
  - What: The arbitrary `plan_key` and a `source` label (default "manual"). Unique per billable.
  - How it’s used: `PlanResolver` checks Pay → manual assignment → default plan. You can call `assign_pricing_plan!` and `remove_pricing_plan!` on the billable.

## Performance & correctness

- Live DB counting for persistent caps; no counter caches.
- Row-level locks for grace state; retries on deadlocks.
- Efficient upserts for per-period usage (PG) or transaction fallback.
- Per-period enforcement state resets at window boundaries (warnings and grace are per-window).

## Testing

The gem ships with comprehensive Minitest coverage for plans, registry, plan resolution, limit checking, grace manager, model mixins, association-based DSL, controller guards (including `for:`), dynamic callbacks, and view helpers. We test grace semantics, thresholds, concurrency/idempotency, custom error messages, complex associations, late binding, naming, and edge cases.

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

## Controller ergonomics

- Dynamic feature guards: `enforce_<feature_key>!` resolves the billable and raises `PricingPlans::FeatureDenied` with a friendly upgrade message if disallowed.
- Limit guard: `require_plan_limit!(limit_key, billable:, by: 1)` returns a `Result` object with:
  - `ok?`, `warning?`, `grace?`, `blocked?`
  - `state` in `:within | :grace | :blocked`
  - `message` human with clear CTA
  - `metadata` with `limit_amount`, `current_usage`, `percent_used`, and optional `grace_ends_at`
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
