# Define pricing plans in `pricing_plans.rb`

You define plans and their limits and features as code in the `pricing_plans.rb` initializer. The `pricing_plans` offers you a DSL that makes plan definition intuitive and read like plain English.

To define a free plan, for example, you would do:

```ruby
PricingPlans.configure do |config|
  plan :free do
    price 0
    default!
  end
end
```

That's the basics! Let's dive in.

> [!IMPORTANT]
> You must set a default plan (either mark one with `default!` in the plan DSL or set `config.default_plan = :your_plan_key`).

## Define what each plan gives

Plans are **secure by default**: features are disabled and limits are set to 0 unless explicitly configured.

At a high level, a plan does **two** things:
  (1) Gate features
  (2) Enforce limits (quotas)

## (1) Gate features in a plan

Let's start by giving access to certain features. For example, our free plan could give users API access:

```ruby
PricingPlans.configure do |config|
  plan :free do
    price 0

    allows :api_access
  end
end
```

We're just **defining** what the plan does now. Later, we'll see [all the methods we can use to enforce these limits and gate these features](#gate-features-in-controllers) very easily.


**Features and limits are secure by default**: features are disabled and limits are set to 0 unless explicitly allowed. For clarity, you can explicitly state what a plan disallows, but this is just cosmetic:

```ruby
PricingPlans.configure do |config|
  plan :free do
    price 0

    allows :api_access
    disallows :premium_features
  end
end
```

This wouldn't do anything, though, because all features are disabled by default; but it makes it obvious what the plan does and doesn't.

## (2) Enforce limits (quotas) in a plan

The other thing plans can do is enforce a limit. We can define limits like this:

```ruby
PricingPlans.configure do |config|
  plan :free do
    price 0

    allows :api_access

    limits :projects, to: 3
  end
end
```

The `limits :projects, to: 3` does exactly that: whoever has this plan can only have three projects at most. We'll see later [how to tie this limit to the actual model relationship](#models), but for now, we're just **defining** the limit.

### `after_limit`: Define what happens after a limit is reached

What happens after a limit is reached is controlled by `after_limit`. The default is `:block_usage`. You can customize per limit. Examples:

```ruby
# Just warn (never block):
PricingPlans.configure do |config|
  plan :free do
    price 0
    allows :api_access
    limits :projects, to: 3, after_limit: :just_warn
  end
end
```

If we want to prevent more resources being created after the limit has been reached, we can `:block_usage`:

```ruby
# Block immediately:
PricingPlans.configure do |config|
  plan :free do
    price 0
    allows :api_access
    limits :projects, to: 3, after_limit: :block_usage
  end
end
```

However, we can be nicer and give users a bit of a grace period after the limit has been reached. To do that, we use `:grace_then_block`:

```ruby
# Opt into grace, then block:
PricingPlans.configure do |config|
  plan :free do
    price 0
    allows :api_access
    limits :projects, to: 3, after_limit: :grace_then_block
  end
end
```

We can also specify how long the grace period is:

```ruby
PricingPlans.configure do |config|
  plan :free do
    price 0
    allows :api_access
    limits :projects, to: 3, after_limit: :grace_then_block, grace: 7.days
  end
end
```

In summary: persistent caps count live rows (per plan owner model). When over the cap:
  - `:just_warn` → validation passes; use controller guard to warn.
  - `:block_usage` → validation fails immediately (uses `error_after_limit` if set).
  - `:grace_then_block` → validation fails once grace is considered “blocked” (we track and switch from grace to blocked).

Note: `grace` is only valid with blocking behaviors. We’ll raise at boot if you set `grace` with `:just_warn`.

### Per‑period allowances

Besides persistent caps, a limit can be defined as a per‑period allowance that resets each window. Example:

```ruby
plan :pro do
  # Allow up to 3 custom models per calendar month
  limits :custom_models, to: 3, per: :calendar_month
end
```

Accepted `per:` values:
- `:billing_cycle` (default globally; respects Pay subscription anchors if available, else falls back to calendar month)
- `:calendar_month`, `:calendar_week`, `:calendar_day`
- A callable: `->(plan_owner) { [start_time, end_time] }`
- An ActiveSupport duration: `2.weeks` (window starts at beginning of day)

Per‑period usage is tracked in [the `PricingPlans::Usage` model (`pricing_plans_usages` table)](#why-the-models) and read live. Persistent caps do not use this table.

#### How period windows are calculated

- **Default period**: Controlled by `config.period_cycle` (defaults to `:billing_cycle`). You can override per limit with `per:`.
- **Billing cycle**: When `pay` is available, we use the subscription’s anchors (`current_period_start`/`current_period_end`). If not available, we fall back to a monthly window anchored at the subscription’s `created_at`. If there is no subscription, we fall back to calendar month.
- **Calendar windows**: `:calendar_month`, `:calendar_week`, `:calendar_day` map to `beginning_of_* … end_of_*` for the current time.
- **Duration windows**: For `ActiveSupport::Duration` (e.g., `2.weeks`), the window starts at `beginning_of_day` and ends at `start + duration`.
- **Custom callable**: You can pass `->(plan_owner) { [start_time, end_time] }`. We validate that both are present and `end > start`.

#### Automatic usage tracking (race‑safe)

- Include `limited_by_pricing_plans` on the model that represents the metered object. On `after_create`, we atomically upsert/increment the current period’s usage row for that `plan_owner` and `limit_key`.
- Concurrency: we de‑duplicate with a uniqueness constraint and retry on `RecordNotUnique` to increment safely.
- Reads are live: `LimitChecker.current_usage_for(plan_owner, :key)` returns the current window’s `used` (or 0 if none).

Callback timing:
- We increment usage in an `after_create` callback (not `after_commit`). This runs inside the same database transaction as the record creation, so if the outer transaction rolls back, the usage increment rolls back as well.

#### Grace/warnings and period rollover (explicit semantics)

- State lives in `pricing_plans_enforcement_states` per plan_owner+limit.
- Per‑period limits:
  - We stamp the active window on the state; when the window changes, stale state is discarded automatically (warnings re‑arm and grace resets at each new window).
  - Warnings: thresholds re‑arm every window; the same threshold can emit again in the next window.
  - Grace: if `:grace_then_block`, grace is per window. A new window clears prior grace/blocked state.
- Persistent caps:
  - Warnings are monotonic: once a higher `warn_at` threshold has been emitted, we do not re‑emit lower or equal thresholds again unless you clear state via `PricingPlans::GraceManager.reset_state!(plan_owner, :limit_key)`.
  - Grace is absolute: if `:grace_then_block`, we start grace once the limit is exceeded. It expires after the configured duration. There is no automatic reset tied to time windows. Enforcement for creates is still driven by “would this action exceed the cap now?”. If usage drops below the cap, create checks will pass again even if a prior state exists.
  - You may clear any existing warning/grace/blocked state manually with `reset_state!`.

#### Example: usage resets next period

```ruby
# pro allows 3 custom models per month
PricingPlans::Assignment.assign_plan_to(org, :pro)

travel_to(Time.parse("2025-01-15 12:00:00 UTC")) do
  3.times { org.custom_models.create!(name: "Model") }
  PricingPlans::LimitChecker.plan_limit_remaining(org, :custom_models)
  # => 0
  result = PricingPlans::ControllerGuards.require_plan_limit!(:custom_models, plan_owner: org)
  result.grace? # => true when after_limit: :grace_then_block
end

travel_to(Time.parse("2025-02-01 12:00:00 UTC")) do
  # New window — counters reset automatically
  PricingPlans::LimitChecker.plan_limit_remaining(org, :custom_models)
  # => 3
end
```

### Warn users when they cross a limit threshold

We can also set thresholds to warn our users when they're halfway through their limit, approaching the limit, etc. To do that, we first set up trigger thresholds with `warn_at:`

```ruby
PricingPlans.configure do |config|
  plan :free do
    price 0

    allows :api_access

    limits :projects, to: 3, after_limit: :grace_then_block, grace: 7.days, warn_at: [0.5, 0.8, 0.95]
  end
end
```

And then, for each threshold and for each limit, an event gets triggered, and we can configure its callback in the `pricing_plans.rb` initializer:

```ruby
config.on_warning(:projects) do |plan_owner, threshold|
  # send a mail or a notification
  # this fires when :projects crosses 50%, 80% and 95% of its limit
end

# Also available:
config.on_grace_start(:projects) do |plan_owner, grace_ends_at|
  # notify grace started; ends at `grace_ends_at`
end
config.on_block(:projects) do |plan_owner|
  # notify usage is now blocked for :projects
end
```

If you only want a scope, like active projects, to count towards plan limits, you can do:

```ruby
PricingPlans.configure do |config|
  plan :free do
    price 0

    allows :api_access

    limits :projects, to: 3, count_scope: :active
  end
end
```

(Assuming, of course, that your `Project` model has an `active` scope)

**Undefined limits default to 0 (blocked).** To explicitly allow unlimited access, use the `unlimited` helper:

```ruby
PricingPlans.configure do |config|
  plan :enterprise do
    price 999
    allows :api_access
    unlimited :projects  # Explicit unlimited
    # :storage undefined → 0 (blocked)
  end
end
```

### "Limits" API reference

To summarize, here's what persistent caps (plan limits) are:
  - Counting is live: `SELECT COUNT(*)` scoped to the plan owner association, no counter caches.
  - Validation on create: blocks immediately on `:block_usage`, or blocks when grace is considered “blocked” on `:grace_then_block`. `:just_warn` passes.
  - Deletes automatically lower the count. Backfills simply reflect current rows.

  - Filtered counting via count_scope: scope persistent caps to active-only rows.
    - Idiomatic options:
      - Plan DSL with AR Hash: `limits :licenses, to: 25, count_scope: { status: 'active' }`
      - Plan DSL with named scope: `limits :activations, to: 50, count_scope: :active`
      - Plan DSL with multiple: `limits :seats, to: 10, count_scope: [:active, { kind: 'paid' }]`
  - Macro form on the child model: `limited_by_pricing_plans :licenses, plan_owner: :organization, count_scope: :active`
  - plan_owner‑side convenience: `has_many :licenses, limited_by_pricing_plans: { limit_key: :licenses, count_scope: :active }`
  - Full freedom: `->(rel) { rel.where(status: 'active') }` or `->(rel, plan_owner) { rel.where(organization_id: plan_owner.id) }`
    - Accepted types: Symbol (named scope), Hash (where), Proc (arity 1 or 2), or Array of these (applied left-to-right).
    - Precedence: plan-level `count_scope` overrides macro-level `count_scope`.
    - Restriction: `count_scope` only applies to persistent caps (not allowed on per-period limits).
    - Performance: add indexes for your filters (e.g., `status`, `deactivated_at`).


## Define user-facing plan attributes

Since `pricing_plans.rb` is our single source of truth for plans, we can define plan information we can later use to show pricing tables, like plan name, description, and bullet points. We can also override the price for a string, and we can set a CTA button text and URL to link to:

```ruby
PricingPlans.configure do |config|
  plan :free do
    price_string "Free!"

    name "Free Plan" # optional, would default to "Free" as inferred from the :free key
    description "A plan to get you started"
    bullets "Basic features", "Community support"

    cta_text "Subscribe"
    # In initializers, prefer a string path/URL or set a global default CTA in config.
    # Route helpers are not available here.
    cta_url  "/pricing"

    allows :api_access

    limits :projects, to: 3
  end
end
```

You can also make a plan `default!`; and you can make a plan `highlighted!` to help you when building a pricing table.

### Hide plans from public lists

You can mark a plan as `hidden!` to exclude it from public-facing plan lists (`PricingPlans.plans`, `PricingPlans.for_pricing`, `PricingPlans.view_models`). Hidden plans are still accessible internally and can be assigned to users.

**Use cases for hidden plans:**
- **Default plan for unsubscribed users**: Create a `hidden!` plan with zero limits as your default for users who haven't subscribed yet. This is useful, for example, if you don't want free users in your app (everyone needs to pay) -- the `hidden!` plan would get assigned to every user by default (to implicitly block access to all features) until they subscribe
- **Grandfathered plans**: Old plans you no longer offer to new customers, but existing users still have
- **Internal/testing plans**: Plans for employees, beta testers, or special partnerships
- **Deprecated plans**: Plans being phased out but still active for some users

```ruby
PricingPlans.configure do |config|
  # Hidden default plan for users who haven't subscribed
  plan :unsubscribed do
    price 0
    hidden!  # Won't appear on pricing page
    default!
    # No limits defined - everything defaults to 0 (blocked)
  end

  # Visible plans for your pricing page
  plan :starter do
    price 10
    limit :projects, to: 5
  end

  # Grandfathered plan (hidden from new customers)
  plan :legacy_2020 do
    price 15
    hidden!  # Existing customers keep it, but won't show on pricing page
    limit :projects, to: 100
  end
end
```

**Important notes:**
- Hidden plans can be the `default!` plan (common pattern for "unsubscribed" users)
- Hidden plans **cannot** be the `highlighted!` plan (validation error - highlighted plans must be visible)
- Users can still be on hidden plans (via Pay subscription, manual assignment, or default)
- Internal APIs (`Registry.plans`, `PlanResolver`) can still access hidden plans
- Pay gem can still resolve subscriptions to hidden plans (useful for grandfathered customers)

## Link paid plans to Stripe prices (requires `pay`)

If we're defining a paid plan, and if you're already using the `pay` gem, you can omit defining the explicit price, and just let the gem read the actual price from Stripe via `pay`:

```ruby
PricingPlans.configure do |config|
  plan :pro do
    stripe_price "price_123abc"

    description "For growing teams and businesses"
    bullets "Advanced features", "Priority support", "API access"

    allows :api_access, :premium_features
    limits :projects, to: 10
    unlimited :team_members
    highlighted!
  end
end
```

If you have monthly and yearly prices for the same plan, you can define them like:

```ruby
PricingPlans.configure do |config|
  plan :pro do
    stripe_price month: "price_123abc", year: "price_456def"
  end
end
```

`stripe_price` accepts String or Hash (e.g., `{ month:, year:, id: }`) and the `pricing_plans` PlanResolver maps against Pay's `subscription.processor_plan`.


## Example: define an enterprise plan

A common use case of pricing pages is adding a free and an enterprise plan around the regular paid plans that you may define in Stripe. The free plan is usually just a limited free tier, not associated with any external price ID; while the "Enterprise" plan may just redirect users to a sales email. To achieve this, we can do:

```ruby
# Your free plan here

# Then your paid plans here, linked to Stripe IDs

# And finally, an enterprise plan:
plan :enterprise do
  price_string  "Contact"

  description   "Get in touch and we'll fit your needs."
  bullets       "Custom limits", "Dedicated SLAs", "Dedicated support"
  cta_text      "Contact us"
  cta_url       "mailto:sales@example.com"

  unlimited :products
  allows    :api_access, :premium_features
end
```