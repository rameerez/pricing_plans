Don’t recommend inline enforce_plan_limit! inside action bodies
README shows calling enforce_plan_limit! directly in an action method. If blocked, this method throws :abort intended for before_action chains, which will raise an uncaught throw in an action.
Recommend either:
Use before_action, or
Use require_plan_limit! inside actions and branch on the result, or
Use PricingPlans::JobGuards.with_plan_limit in non-controller contexts.

You can also use all these methods inline within any controller action, instead of a callback:
```ruby
def create
  enforce_plan_limit!(:products, on: :current_organization, redirect_to: pricing_path)
  Product.create!(...)
  redirect_to products_path
end
```

Another example:
```ruby
def import
  enforce_products_limit!(on: :current_organization, by: 5)
  ProductImporter.import!(current_organization, rows)
  redirect_to products_path
end
```

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
