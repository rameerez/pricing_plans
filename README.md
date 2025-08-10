# 💵 `pricing_plans` - Define and enforce pricing plan limits in your Rails app

[![Gem Version](https://badge.fury.io/rb/pricing_plans.svg)](https://badge.fury.io/rb/pricing_plans)

Use `pricing_plans` as the single source of truth for pricing plans and plan limits in your Rails apps. It provides methods you can use across your app to consistently check whether users can perform an action based on the plan they're currently subscribed to.

Define plans and their limits:
```ruby
plan :pro do
  limits :projects, to: 5.max
  allows :api_access
end
```

Then, gate features in your controllers:
```ruby
before_action :enforce_api_access!, only: [:create]
```

Enforce limits in your models too:
```ruby
class User < ApplicationRecord
  has_many :projects, :limited_by_pricing_plans
end
```

Or anywhere in your app:
```ruby
@user.remaining_projects
# => 2
```

> [!TIP]
> The `pricing_plans` gem works seamlessly out of the box with [`pay`](https://github.com/pay-rails/pay) and [`usage_credits`](https://github.com/rameerez/usage_credits/). More info [here](#using-with-pay-andor-usage_credits).

## Quickstart

Add this to your Gemfile:

```ruby
gem "pricing_plans"
```

Then install the gem:

```bash
bundle install
rails g pricing_plans:install
rails db:migrate
```

This will generate and migrate [the necessary models](#why-the-models) to make the gem work. It will also create a `config/initializers/pricing_plans.rb` file where you need to define your pricing plans, as defined in TODO: link to section.

Once installed, just add the model mixin to the actual `billable` model on which limits should be enforced (like: `User`, `Organization`, etc.):

```ruby
class User < ApplicationRecord
  include PricingPlans::Billable
end
```

And that automatically gives your model all plan-limiting helpers and methods, so you can proceed to enforce plan limits in your models like this:
```ruby
class User < ApplicationRecord
  include PricingPlans::Billable

  has_many :projects, limited_by_pricing_plans: { error_after_limit: "Too many projects!" }, dependent: :destroy
end
```

There's many helper methods to help you enforce limits and feature gating in controller, methods, and everywhere in your app: read the [full API reference](#available-methods--full-api-reference).


## Why this gem exists

`pricing_plans` helps you avoid reimplementing feature gating over and over again across your project.

If you've ever had to implement pricing plan limits, you probably found yourself writing code like this everywhere in your app:

```ruby
if user_signed_in? && current_user.payment_processor&.subscription&.processor_plan == "pro" && current_user.projects.count <= 5
  # ...
elsif user_signed_in? && current_user.payment_processor&.subscription&.processor_plan == "premium" && current_user.projects.count <= 10
  # ...
end
```

You end up duplicating this kind of snippet for every plan and feature, and for every view and controller.

This code is brittle, tends to be full of magical numbers and nested convoluted logic; and plan enforcement tends to be scattered across the entire codebase. If you change something in your pricing table, it's highly likely you'll have to change the same magical number or logic in many different places, leading to bugs, inconsistencies, customer support tickets, and maintenance hell.

`pricing_plans` aims to offer a centralized, single-source-of-truth way of defining & handling pricing plans, so you can enforce plan limits with reusable helpers that read like plain English.

## Define pricing plans

two limits: count and feature gate

connect with stripe ids monthly and yearly

## Usage: available methods & full API reference

Assuming you've correctly installed the gem and configured your pricing plans in `pricing_plans.rb` and your "billable" model (`User`, `Organization`, etc.) has the model mixin `include PricingPlans::Billable`, here's everything you can do:

### Models

The class to which you add the `include PricingPlans::Billable` automatically gains these helpers to check limits:

```ruby
# Check limits for a relationship
user.plan_limit_remaining(:projects)              # => integer or :unlimited
user.plan_limit_percent_used(:projects)           # => Float percent
user.within_plan_limits?(:projects, by: 1)        # => true/false

# Grace helpers
user.grace_active_for?(:projects)                 # => true/false
user.grace_ends_at_for(:projects)                 # => Time or nil
user.grace_remaining_seconds_for(:projects)       # => Integer seconds
user.grace_remaining_days_for(:projects)          # => Integer days (ceil)
user.plan_blocked_for?(:projects)                 # => true/false (considering after_limit policy)
```

We also add syntactic sugar methods. For example, if your plan defines a limit for `:projects` and you have a `has_many :projects` relationship, you also get these methods:
```ruby
# Check limits (per `limits` key)
user.projects_remaining
user.projects_percent_used
user.projects_within_plan_limits?

# Grace helpers (per `limits` key)
user.projects_grace_active?
user.projects_grace_ends_at
user.projects_blocked?
```

These methods are dynamically generated for every `has_many :<limit_key>`, like this:
- `<limit_key>_remaining`
- `<limit_key>_percent_used`
- `<limit_key>_within_plan_limits?` (optionally: `<limit_key>_within_plan_limits?(by: 1)`)
- `<limit_key>_grace_active?`
- `<limit_key>_grace_ends_at`
- `<limit_key>_blocked?`

You can also check for feature flags like this:
```ruby
user.plan_allows?(:api_access)                    # => true/false
```

And, if you want to get aggregates across all keys instead of checking them individually:
```ruby
# Aggregates across keys
user.any_grace_active_for?(:products, :activations)
user.earliest_grace_ends_at_for(:products, :activations)
```

You can also check and override the current pricing plan for any user:
```ruby
user.current_pricing_plan                         # => PricingPlans::Plan
user.assign_pricing_plan!(:pro)                   # manual assignment override
user.remove_pricing_plan!                         # remove manual override (fallback to default)
```

And finally, you get very thin convenient wrappers if you're using `pay`:
```ruby
# Pay (Stripe) convenience (returns false/nil when Pay is absent)
# Note: this is billing-facing state, distinct from our in-app
# enforcement grace which is tracked per-limit.
user.pay_subscription_active?                     # => true/false
user.pay_on_trial?                                # => true/false
user.pay_on_grace_period?                         # => true/false
```

### Controllers

First of all, the gem needs a way to know what the current billable object is (the current user, current organization, etc.)

`pricing_plans` will [auto-try common conventions](/lib/pricing_plans/controller_guards.rb) like `current_user`, `current_organization`, `current_account`... in case any of these methods are already defined in your controller (for example: it works out of the box with Devise)

If none of those are defined, or you have custom logic, we recommend defining a current billable helper in your `ApplicationController`:
```ruby
class ApplicationController < ActionController::Base
  # Adapt to your auth/session logic
  def current_organization
    # Your lookup here (e.g., current_user.organization)
  end
end
```

You can also specify which controller helper `pricing_plans` should use in the `pricing_plans.rb` initializer:
```ruby
  config. ## TODO: do we have this? we should
```

Once that's configured, you can feature gate any controller action with:
```ruby
before_action :enforce_api_access!, only: [:create]
```

These controller helper methods are dynamically generated for each of the features `<feature_key>` you defined in your plans:
```ruby
enforce_<feature_key>!
```

You can also specify which the current billable object is, in each controller callback:
```ruby
before_action { enforce_api_access!(on: :current_team) }
```

When the feature is disallowed, the controller will raise a `FeatureDenied` (we rescue it for you by default). You can configure what happens when a feature is disallowed, by overwriting the:
```ruby
```

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

When a limit check blocks an action, controllers now call a centralized handler if present:

```ruby
# ApplicationController (override as needed)
private
def handle_pricing_plans_limit_blocked(result)
  # Default shipped behavior (HTML): flash + redirect_to(pricing_path) if defined; else render 403
  # You can customize globally here. The Result carries rich context:
  # - result.limit_key, result.billable, result.message, result.metadata
  redirect_to(pricing_path, status: :see_other, alert: result.message)
end
```

Details:
- `enforce_plan_limit!` prefers this handler when `result.blocked?` to centralize redirects/messages.
- We also ship a sensible default implementation in `PricingPlans::ControllerRescues` that responds for HTML/JSON. Define your own in `ApplicationController` to override.
- JSON: we return `{ error, limit, plan }` with 403 by default.



Default behavior out of the box:

- Disallowed features raise `PricingPlans::FeatureDenied`.
- The engine maps this to HTTP 403 by default and installs a controller rescue that:
  - HTML/Turbo: redirects to `pricing_path` with an alert (303 See Other) if the helper exists; otherwise renders a 403 with the message.
  - JSON: returns `{ error: message }` with 403.

You can override the behavior by defining `handle_pricing_plans_feature_denied(error)` in your `ApplicationController`, or by adding your own `rescue_from PricingPlans::FeatureDenied`.


We provide both dynamic, English-y helpers and lower-level primitives.

- Dynamic feature guard (before_action-friendly):


- Dynamic limit guard (before_action-friendly):
  - `enforce_<limit_key>_limit!(on:, by: 1, redirect_to: nil, allow_system_override: false)`
    - **Defaults**:
      - `by: 1` (omit for single-create). `on:` is a friendly alias for `billable:`.
      - Redirect resolution order when blocked:
        1. `redirect_to:` option passed to the call
        2. Per-controller default `self.pricing_plans_redirect_on_blocked_limit = :pricing_path` (Symbol | String | Proc)
        3. Global default `config.redirect_on_blocked_limit` (Symbol | String | Proc)
        4. `pricing_path` if available
        5. Otherwise render HTTP 403 (JSON/plain)
      - Aborts the filter chain when blocked.
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
  # Preferred sugar — no lambda required, `by:` defaults to 1, billable inferred
  # Optionally set a per-controller default redirect:
  # self.pricing_plans_redirect_on_blocked_limit = :pricing_path
  before_action :enforce_licenses_limit!, only: :create

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

Global default redirect (optional):

```ruby
# config/initializers/pricing_plans.rb
PricingPlans.configure do |config|
  config.redirect_on_blocked_limit = :pricing_path # or "/pricing" or ->(result) { pricing_path }
end
```

Per-controller default (optional):

```ruby
class ApplicationController < ActionController::Base
  self.pricing_plans_redirect_on_blocked_limit = :pricing_path
end

Redirect resolution cheatsheet (priority):

1) `redirect_to:` option on the call
2) Per-controller `self.pricing_plans_redirect_on_blocked_limit`
3) Global `config.redirect_on_blocked_limit`
4) `pricing_path` helper (if present)
5) Fallback: render 403 (HTML or JSON)

Per-controller default accepts:

- Symbol: helper method name (e.g., `:pricing_path`)
- String: path or URL (e.g., `"/pricing"`)
- Proc: `->(result) { pricing_path }` (instance-exec'd in the controller)

Global default accepts the same types. The Proc receives the `Result` so you can branch on `limit_key`, etc.

Recommended patterns:

- Set a single global default in your initializer.
- Override per controller only if UX differs for a section.
- Use the dynamic helpers as symbols in before_action for maximum clarity:
  ```ruby
  before_action :enforce_projects_limit!, only: :create
  before_action :enforce_api_access!
  ```
```



### App-wide helpers

### Build a pricing plan table

### Defining plans & available configuration options in `pricing_plans.rb`

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

## Using with `pay` and/or `usage_credits`

`pricing_plans` is designed to work seamlessly with other complementary popular gems like `pay` (to handle actual subscriptions and payments), and `usage_credits` (to handle credit-like spending and refills)

### Using `pricing_plans` with the `pay` gem

### Using `pricing_plans` with the `usage_credits` gem

Credits vs Limits — decision table

- Use `includes_credits` (via `usage_credits` gem) for metered events and overage models (increment-only, wallet-like semantics, with purchase/overage handling outside this gem).
- Use `limits` here when you want either:
  - Persistent caps: concurrent resource ceilings (e.g., projects, seats).
  - Discrete per-period allowances: rare monthly allowances that reset per billing window (e.g., “3 custom models per month”).

Rules enforced at boot:
- You cannot define both `includes_credits` and a per-period `limits` for the same key. This prevents double-metering.
- When `usage_credits` is present, `includes_credits` must point to a known operation, or boot will fail.


## Why the models?

The `pricing_plans` gem needs three new models in the schema in order to work: `Assignment`, `EnforcementState`, and `Usage`. Why are they needed?

- `PricingPlans::Assignment` allow manual plan overrides independent of billing system (or before you wire up Stripe/Pay). Great for admin toggles, trials, demos.
  - What: The arbitrary `plan_key` and a `source` label (default "manual"). Unique per billable.
  - How it’s used: `PlanResolver` checks Pay → manual assignment → default plan. You can call `assign_pricing_plan!` and `remove_pricing_plan!` on the billable.

- `PricingPlans::EnforcementState` tracks per-billable per-limit enforcement state for persistent caps and per-period allowances (grace/warnings/block state) in a race-safe way.
  - What: `exceeded_at`, `blocked_at`, last warning info, and a small JSON `data` column where we persist plan-derived parameters like grace period seconds.
  - How it’s used: When you exceed a limit, we upsert/read this row under row-level locking to start grace, compute when it ends, flip to blocked, and to ensure idempotent event emission (`on_warning`, `on_grace_start`, `on_block`).

- `PricingPlans::Usage` tracks per-period allowances (e.g., “3 projects per month”). Persistent caps don’t need a table because they are live counts.
  - What: `period_start`, `period_end`, and a monotonic `used` counter with a last-used timestamp.
  - How it’s used: On create of the metered model, we increment or upsert the usage for the current window (based on `PeriodCalculator`). Reads power `remaining`, `percent_used`, and warning thresholds.



-----------------------------
-----------------------------
-----------------------------
-----------------------------
-----------------------------
-----------------------------


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
      - Full freedom: `->(rel) { rel.where(status: 'active') }` or `->(rel, org) { rel.where(organization_id: user.id) }`
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

### Multi-limit UX helpers

Small helpers that compute a single state/message across a set of limits:

```ruby
# Highest severity across keys for a billable: :ok | :warning | :grace | :blocked
highest_severity_for(current_organization, :products, :licenses, :activations)

# Combine per-limit human messages into a single banner string (or nil if all ok)
combine_messages_for(current_organization, :products, :licenses, :activations)
```

These pair nicely with a single banner:

```erb
<% severity = highest_severity_for(current_organization, :products, :licenses, :activations) %>
<% if severity != :ok %>
  <div class="pricing-plans-banner pricing-plans-banner--<%= severity %>">
    <%= combine_messages_for(current_organization, :products, :licenses, :activations) %>
  </div>
<% end %>
```

### Bulk dashboard status

Fetch statuses for multiple keys at once:

```ruby
statuses = plan_limit_statuses(:products, :licenses, :activations, billable: current_organization)
# => {
#      products: { configured:, limit_amount:, current_usage:, percent_used:, grace_active:, blocked:, ... },
#      licenses: { ... },
#      activations: { ... }
#    }
```

### Plan label helper for pricing UI

Normalize price labels for view conditionals:

```ruby
name, price_label = plan_label(plan)
# Examples: ["Free", "Free"], ["Pro", "$29/mo"], ["Enterprise", "Contact"]
```

### Suggest next plan (upgrade path)

Suggests the smallest plan that satisfies current usage across relevant limit keys:

```ruby
next_plan = suggest_next_plan_for(current_organization)
# or restrict to explicit keys
next_plan = suggest_next_plan_for(current_organization, keys: [:products, :licenses])

if next_plan && next_plan != current_pricing_plan(current_organization)
  link_to "Upgrade to #{next_plan.name}", pricing_path
end
```

### CTA and Pay (Stripe/Paddle/etc.)

When a plan has a `stripe_price`, the default `cta_text` becomes "Subscribe" and the default `cta_url` is nil. We intentionally do not hardwire Pay integration in the gem views because the host app controls processor, routes, and checkout UI. You have two simple options (plus an auto option):

- Use your own controller action to start checkout and set `cta_url` to that path. Inside the action, call your Pay integration (e.g., Stripe Checkout, Billing Portal, or Paddle). See the official Pay docs (bundled here as `docs/pay.md`) for the exact APIs.
- Override the pricing partial `_plan_card.html.erb` to attach your desired data attributes for Pay’s JavaScript integrations (e.g., Paddle.js, Lemon.js) or link to a Checkout URL.
- Auto: set `config.auto_cta_with_pay` with a proc `(billable, plan, view)` and call `plan.cta_url(view:, billable:)` or the helper `pricing_plans_cta_url(plan, billable:, view:)`.

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

We do not ship controllers or views. Implement a simple controller action in your app to start checkout and wire your own routes/UI.

### Pay integration (what you need to do)

If you want Stripe/Paddle/Lemon Squeezy checkout to power your plan CTAs, install and configure the Pay gem in your app. At minimum:

1) Add the gems and run the Pay generators/migrations (see `docs/pay.md`).
2) Configure credentials and webhooks per Pay’s docs.
3) On your billable model, add `pay_customer` and ensure it responds to `email` (and optionally `name`).
4) Provide a controller action to start checkout (Stripe example above; Paddle/Lemon use overlay/hosted JS with data attributes).
5) Point CTA buttons to your action or override the pricing partial to embed the attributes.

We do not add any Pay routes or include concerns automatically; you stay in control.

### View helpers for pricing UI

- Plans: `PricingPlans.plans #=> [Plan, ...]`
- Dashboard data: `PricingPlans.for_dashboard(current_organization)` returns `OpenStruct` with `plans`, `popular_plan_key`, `current_plan`.
- Marketing data: `PricingPlans.for_marketing`.
- CTA helpers: `pricing_plans_cta_url(plan, billable:, view:)`, `pricing_plans_cta_button(plan, billable:, view:, context: :dashboard)`.
- Usage/status bulk: `pricing_plans_status(billable, limits: [:products, :licenses, :activations])`.
- Overage report with human message: `PricingPlans::OverageReporter.report_with_message(billable, :free)`.
- Suggest next plan: `PricingPlans.suggest_next_plan_for(billable)`.


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

## Complex names and associations

We test and support:

- Custom `class_name:` and `foreign_key:` on `has_many`.
- Namespaced child classes (e.g., `Deeply::NestedResource`).
- Late definition of child classes (limits and sugar wire up when the constant resolves).
- Explicit `limit_key:` to decouple the key from the association name.

## Performance & correctness

- Live DB counting for persistent caps; no counter caches.
- Row-level locks for grace state; retries on deadlocks.
- Efficient upserts for per-period usage (PG) or transaction fallback.
- Per-period enforcement state resets at window boundaries (warnings and grace are per-window).

## Testing

The gem ships with comprehensive Minitest coverage for plans, registry, plan resolution, limit checking, grace manager, model mixins, association-based DSL, controller guards (including `for:`), dynamic callbacks, and view helpers. We test grace semantics, thresholds, concurrency/idempotency, custom error messages, complex associations, late binding, naming, and edge cases.

## License

MIT



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

## Performance & correctness

- Live DB counting for persistent caps; no counter caches.
- Row-level locks for grace state; retries on deadlocks.
- Efficient upserts for per-period usage (PG) or transaction fallback.
- Per-period enforcement state resets at window boundaries (warnings and grace are per-window).

## Testing

The gem ships with comprehensive Minitest coverage for plans, registry, plan resolution, limit checking, grace manager, model mixins, association-based DSL, controller guards (including `for:`), dynamic callbacks, view helpers, and visibility helpers. We test grace semantics, thresholds, concurrency/idempotency, complex associations, late binding, naming, Pay parity, window boundaries, and downgrade reporting.
