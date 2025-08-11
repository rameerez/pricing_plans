# 💵 `pricing_plans` - Define and enforce pricing plan limits in your Rails app

[![Gem Version](https://badge.fury.io/rb/pricing_plans.svg)](https://badge.fury.io/rb/pricing_plans)

`pricing_plans` is the single source of truth for pricing plans and plan limits in your Rails apps. It provides methods you can use across your app to consistently check whether users can perform an action based on the plan they're currently subscribed to.

Define plans and their quotas and limits:
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
  has_many :projects, limited_by_pricing_plans: true
end
```

Or anywhere in your app:
```ruby
@user.projects_remaining
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

This will generate and migrate [the necessary models](#why-the-models) to make the gem work. It will also create a `config/initializers/pricing_plans.rb` file where you need to define your pricing plans.

Important:
- You must set a default plan (either mark one with `default!` in the plan DSL or set `config.default_plan = :your_plan_key`).
- In the initializer, we enable integer DSL sugar like `5.max` via `using PricingPlans::IntegerRefinements`.

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

### Some features

Enforcing pricing plans is one of those boring plumbing problems that look easy from a distance but get complex when you try to engineer them for production usage. The poor man's implementation of nested ifs shown in the example above only get you so far, you soon start finding edge cases to consider. Here's some of what we've covered in this gem:

- Safe under load: we use row locks and retries when setting grace/blocked/warning state, and we avoid firing the same event twice. See [grace_manager.rb](lib/pricing_plans/grace_manager.rb).

- Accurate counting: persistent limits count live current rows (using `COUNT(*)`, make sure to index your foreign keys to make it fast at scale); per‑period limits record usage for the current window only. You can filter what counts with `count_scope` (Symbol/Hash/Proc/Array), and plan settings override model defaults. See [limitable.rb](lib/pricing_plans/limitable.rb) and [limit_checker.rb](lib/pricing_plans/limit_checker.rb).

- Clear rules: default is to block when you hit the cap; grace periods are opt‑in. In status/UI, 0 of 0 isn’t shown as blocked. See [plan.rb](lib/pricing_plans/plan.rb), [grace_manager.rb](lib/pricing_plans/grace_manager.rb), and [view_helpers.rb](lib/pricing_plans/view_helpers.rb).

- Simple controllers: one‑liners to guard actions, predictable redirect order (per‑call → per‑controller → global → pricing_path), and an optional central handler. See [controller_guards.rb](lib/pricing_plans/controller_guards.rb).

- Billing‑aware periods: supports billing cycle (when Pay is present), calendar month/week/day, custom time windows, and durations. See [period_calculator.rb](lib/pricing_plans/period_calculator.rb).

## Define pricing plans

You define plans and their limits and features in the `pricing_plans.rb` initializer. To define a free plan, for example, you would do:

```ruby
PricingPlans.configure do |config|
  # Enable integer sugar like 5.max (the installer adds this for you):
  # using PricingPlans::IntegerRefinements

  plan :free do
    price 0
    default!
  end
end
```

That's the basics! Let's dive in.

### Define plan limits (quotas) and features

At a high level, a plan needs to do **two** things:
  1) Gate features
  2) Enforce limits (quotas)

#### 1) Gate features in a plan

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


All features are disabled by default unless explicitly made available with the `allows` keyword. However, for clarity we can explicitly say what the plan disallows:

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

#### 2) Enforce limits (quotas) in a plan

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

##### `after_limit`: Define what happens after a limit is reached

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

In summary: persistent caps count live rows (per billable model). When over the cap:
  - `:just_warn` → validation passes; use controller guard to warn.
  - `:block_usage` → validation fails immediately (uses `error_after_limit` if set).
  - `:grace_then_block` → validation fails once grace is considered “blocked” (we track and switch from grace to blocked).

Note: `grace` is only valid with blocking behaviors. We’ll raise at boot if you set `grace` with `:just_warn`.

##### Per‑period allowances

Besides persistent caps, a limit can be defined as a per‑period allowance that resets each window. Example:

```ruby
plan :pro do
  # Allow up to 3 custom models per calendar month
  limits :custom_models, to: 3, per: :calendar_month
end
```

Accepted `per:` values:
- :billing_cycle (default globally; respects Pay subscription anchors if available, else falls back to calendar month)
- :calendar_month, :calendar_week, :calendar_day
- A callable: `->(billable) { [start_time, end_time] }`
- An ActiveSupport duration: `2.weeks` (window starts at beginning of day)

Per‑period usage is tracked in `pricing_plans_usages` and read live. Persistent caps do not use this table.

##### Warn users when they cross a limit threshold

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
config.on_warning(:projects) do |billable, threshold|
  # send a mail or a notification
  # this fires when :projects crosses 50%, 80% and 95% of its limit
end

# Also available:
config.on_grace_start(:projects) do |billable, grace_ends_at|
  # notify grace started; ends at `grace_ends_at`
end
config.on_block(:projects) do |billable|
  # notify usage is now blocked for :projects
end
```

If you only want a scope, like active projects, to count towards plan limits, you can do:

```ruby
PricingPlans.configure do |config|
  plan :free do
    price 0

    allows :api_access

    limits :projects, to: 3.max, count_scope: :active
  end
end
```

(Assuming, of course, that your `Project` model has an `active` scope)

You can also make something unlimited (again, just syntactic sugar to be explicit, everything is unlimited unless there's an actual limit):

```ruby
PricingPlans.configure do |config|
  plan :free do
    price 0

    allows :api_access

    unlimited :projects
  end
end
```

##### Limit API reference

To summarize, here's what persistent caps (plan limits) are:
  - Counting is live: `SELECT COUNT(*)` scoped to the billable association, no counter caches.
  - Validation on create: blocks immediately on `:block_usage`, or blocks when grace is considered “blocked” on `:grace_then_block`. `:just_warn` passes.
  - Deletes automatically lower the count. Backfills simply reflect current rows.

  - Filtered counting via count_scope: scope persistent caps to active-only rows.
    - Idiomatic options:
      - Plan DSL with AR Hash: `limits :licenses, to: 25, count_scope: { status: 'active' }`
      - Plan DSL with named scope: `limits :activations, to: 50, count_scope: :active`
      - Plan DSL with multiple: `limits :seats, to: 10, count_scope: [:active, { kind: 'paid' }]`
  - Macro form on the child model: `limited_by_pricing_plans :licenses, billable: :organization, count_scope: :active`
  - Billable‑side convenience: `has_many :licenses, limited_by_pricing_plans: { limit_key: :licenses, count_scope: :active }`
  - Full freedom: `->(rel) { rel.where(status: 'active') }` or `->(rel, billable) { rel.where(organization_id: billable.id) }`
    - Accepted types: Symbol (named scope), Hash (where), Proc (arity 1 or 2), or Array of these (applied left-to-right).
    - Precedence: plan-level `count_scope` overrides macro-level `count_scope`.
    - Restriction: `count_scope` only applies to persistent caps (not allowed on per-period limits).
    - Performance: add indexes for your filters (e.g., `status`, `deactivated_at`).


### Define user-facing plan attributes

Since this is our single source of truth for plans, we can define plan information we can later use to show pricing tables, like plan name, description, and bullet points. We can also override the price for a string, and we can set a CTA button text and URL to link to:

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

### Link plans to Stripe prices

If we're defining a paid plan, it's better to omit the explicit price, and just let the gem read the actual price from Stripe (assuming the `pay` gem is set up correctly):

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

## Usage: available methods & full API reference

Assuming you've correctly installed the gem and configured your pricing plans in `pricing_plans.rb`, here's everything you can do:

### Models

#### Define your `Billable` class and add limits to your model

Your `Billable` class is the class on which limits are enforced. It's usually the same class that gets charged for a subscription, the class which "owns" the plan, the class with the `pay_customer` if you're using Pay, etc. It's usually `User`, `Organization`, `Team`, etc.

To define your `Billable` class, just add the model mixin:

```ruby
class User < ApplicationRecord
  include PricingPlans::Billable
end
```

Now you can link `has_many` relationships in this model to `limits` defined in your `pricing_plans.rb`

For example, if you defined a `:projects` limit in your `pricing_plans.rb` like this:

```ruby
plan :pro do
  limits :projects, to: 5
end
```

then you can link `:projects` to any `has_many` relationship on the `Billable` model (`User`, in this example):

```ruby
class User < ApplicationRecord
  include PricingPlans::Billable

  has_many :projects, limited_by_pricing_plans: true
end
```

The `:limited_by_pricing_plans` infers that the association name (:projects) is the same as the limit key you defined on `pricing_plans.rb`. If that's not the case, you can make it explicit:

```ruby
class User < ApplicationRecord
  include PricingPlans::Billable

  has_many :custom_projects, limited_by_pricing_plans: { limit_key: :projects }
end
```

In general, you can omit the limit key when it can be inferred from the model (e.g., `Project` → `:projects`).

`limited_by_pricing_plans` plays nicely with every other ActiveRecord validation you may have in your relationship:
```ruby
class User < ApplicationRecord
  include PricingPlans::Billable

  has_many :projects, limited_by_pricing_plans: true, dependent: :destroy
end
```

You can also customize the validation error message by passing `error_after_limit`. This error message behaves like other ActiveRecord validation, and will get attached to the record upon failed creation because of limits:
```ruby
class User < ApplicationRecord
  include PricingPlans::Billable

  has_many :projects, limited_by_pricing_plans: { error_after_limit: "Too many projects!" }, dependent: :destroy
end
```


#### Enforce limits in your `Billable` class

The `Billable` class (the class to which you add the `include PricingPlans::Billable` mixin) automatically gains these helpers to check limits:

```ruby
# Check limits for a relationship
user.plan_limit_remaining(:projects)         # => integer or :unlimited
user.plan_limit_percent_used(:projects)      # => Float percent
user.within_plan_limits?(:projects, by: 1)   # => true/false

# Grace helpers
user.grace_active_for?(:projects)            # => true/false
user.grace_ends_at_for(:projects)            # => Time or nil
user.grace_remaining_seconds_for(:projects)  # => Integer seconds
user.grace_remaining_days_for(:projects)     # => Integer days (ceil)
user.plan_blocked_for?(:projects)            # => true/false (considering after_limit policy)
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
user.plan_allows?(:api_access)               # => true/false
```

And, if you want to get aggregates across all keys instead of checking them individually:
```ruby
# Aggregates across keys
user.any_grace_active_for?(:products, :activations)
user.earliest_grace_ends_at_for(:products, :activations)
```

You can also check and override the current pricing plan for any user:
```ruby
user.current_pricing_plan                    # => PricingPlans::Plan
user.assign_pricing_plan!(:pro)              # manual assignment override
user.remove_pricing_plan!                    # remove manual override (fallback to default)
```

And finally, you get very thin convenient wrappers if you're using `pay`:
```ruby
# Pay (Stripe) convenience (returns false/nil when Pay is absent)
# Note: this is billing-facing state, distinct from our in-app
# enforcement grace which is tracked per-limit.
user.pay_subscription_active?                # => true/false
user.pay_on_trial?                           # => true/false
user.pay_on_grace_period?                    # => true/false
```

### Controllers

#### Setting things up for controllers

First of all, the gem needs a way to know what the current billable object is (the current user, current organization, etc.)

`pricing_plans` will [auto-try common conventions](/lib/pricing_plans/controller_guards.rb): `current_organization`, `current_account`, `current_user`, `current_team`, `current_company`, `current_workspace`, `current_tenant`. If you set `billable_class`, we’ll also try `current_<billable_class>`.

If these methods already defined in your controller(s), there's nothing you need to do! For example: `pricing_plans` works out of the box with Devise.

If none of those methods are defined, or you want custom logic, we recommend defining a current billable helper in your `ApplicationController`:
```ruby
class ApplicationController < ActionController::Base
  # Adapt to your auth/session logic
  def current_organization
    # Your lookup here (e.g., current_user.organization)
  end
end
```

You can explicitly configure the billable resolution per controller:
```ruby
class ApplicationController < ActionController::Base
  pricing_plans_billable :current_organization

  # Or pass a block:
  # pricing_plans_billable { current_user&.organization }
end
```

Optionally, you can set a global resolver in the initializer (per-controller still wins):
```ruby
# config/initializers/pricing_plans.rb
PricingPlans.configure do |config|
  # Either:
  config.controller_billable :current_organization
  # Or:
  # config.controller_billable { current_account }
end
```

You can also override the `current_<billable_class>` per helper (with `on: :current_organization` or `on: -> { find_org }`), as we'll see in the next sections.

Once all of this is configured, you can gate features and enforce limits easily in your controllers.

#### Gate features in controllers

Feature-gate any controller action with:
```ruby
before_action :enforce_api_access!, only: [:create]
```

These `enforce_<feature_key>!` controller helper methods are dynamically generated for each of the features `<feature_key>` you defined in your plans. So, for the helper above to work, you would have to have defined a `allows :api_access` in your `pricing_plans.rb` file.

When the feature is disallowed, the controller will raise a `FeatureDenied` (we rescue it for you by default). You can customize the response by overriding `handle_pricing_plans_feature_denied(error)` in your `ApplicationController`:

```ruby
class ApplicationController < ActionController::Base
  private

  # Override the default 403 handler (optional)
  def handle_pricing_plans_feature_denied(error)
    # Custom HTML handling
    redirect_to upgrade_path, alert: error.message, status: :see_other
  end
end
```

You can also specify which the current billable object is **per action** by passing it to the `enforce_` callback via the `on:` param:
```ruby
before_action { enforce_api_access!(on: :current_organization) }
```

Or if you need a lambda:
```ruby
before_action { enforce_api_access!(on: -> { find_org }) }
```

Of course, this is all syntactic sugar for the primitive method, which you can also use:
```ruby
before_action { require_feature!(:api_access, billable: current_organization) }
```

#### Enforce plan limits in controllers

You can enforce limits for any action:
```ruby
before_action :enforce_projects_limit!, only: :create
```

As in feature gating, this is syntactic sugar (`enforce_<limit_key>_limit!`) that gets generated for every `limits` key in `pricing_plans.rb`. You can also use the primitive method:
```ruby
before_action { enforce_plan_limit!(:projects, billable: current_organization) }
```

And you can also pass a custom billable:
```ruby
before_action { enforce_projects_limit!(on: :current_organization) }
# or
before_action { enforce_plan_limit!(:projects, billable: current_organization) }
```

You can also specify a custom redirect path that will override the global config:
```ruby
before_action { enforce_plan_limit!(:projects, billable: current_organization, redirect_to: pricing_path) }
```

In the example aboves, the gem assumes the action to call will only create one extra project. So, if the plan limit is 5, and you're currently at 4 projects, you can still create one extra one, and the action will get called. If your action creates more than one object per call (creating multiple objects at once, importing objects in bulk etc.) you can enforce it will stay within plan limits by passing the `by:` parameter like this:
```ruby
before_action { enforce_projects_limit!(by: 10) }
```

You can also check limits inside a controller action by using `require_plan_limit!` and reading its `result`:
```ruby
def create
  result = require_plan_limit!(:products, billable: current_organization, by: 1)

  if result.blocked? # ok?, warning?, grace?, blocked?, success?
    # result.message is available:
    redirect_to pricing_path, alert: result.message, status: :see_other and return
  end

  # ...
  Product.create!(...)
  redirect_to products_path
end
```

You can define how your application responds when a limit check blocks an action by defining `handle_pricing_plans_limit_blocked` in your controller:

```ruby
class ApplicationController < ActionController::Base
  private

  def handle_pricing_plans_limit_blocked(result)
    # Default behavior (HTML): flash + redirect_to(pricing_path) if defined; else render 403
    # You can customize globally here. The Result carries rich context:
    # - result.limit_key, result.billable, result.message, result.metadata
    redirect_to(pricing_path, status: :see_other, alert: result.message)
  end
end
```

`enforce_plan_limit!` invokes this handler when `result.blocked?`, passing a `Result` enriched with `metadata[:redirect_to]` resolved via:
  1. explicit `redirect_to:` option
  2. per-controller default `self.pricing_plans_redirect_on_blocked_limit`
  3. global `config.redirect_on_blocked_limit`
  4. `pricing_path` helper if available


#### Set up a redirect when a limit is reached

You can configure a global default redirect (optional):

```ruby
# config/initializers/pricing_plans.rb
PricingPlans.configure do |config|
  config.redirect_on_blocked_limit = :pricing_path # or "/pricing" or ->(result) { pricing_path }
end
```

Or a per-controller default (optional):

```ruby
class ApplicationController < ActionController::Base
  self.pricing_plans_redirect_on_blocked_limit = :pricing_path
end
```

Redirect resolution priority:
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
- Use the dynamic helpers as symbols in before_action for clarity:
```ruby
before_action :enforce_projects_limit!, only: :create
before_action :enforce_api_access!
```

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

### Views

We provide some helpers that may come in handy when building views.

- Per‑limit status and bulk:
  - `plan_limit_status(limit_key, billable:)`, `plan_limit_statuses(*keys, billable:)`
  - `pricing_plans_status(billable, limits: [...])`

- Banners/meters:
  - `plan_limit_banner(limit_key, billable:)`
  - `plan_usage_meter(limit_key, billable:)`

- Aggregates:
  - `highest_severity_for(billable, *keys)` and `combine_messages_for(billable, *keys)`

- Pricing UI:
  - `plan_pricing_table(highlight: false)`
  - `plan_label(plan)` → ["Name", "Free" | "$29/mo" | "Contact"]
  - CTA helpers: `pricing_plans_cta_url(plan, billable:, view:)`, `pricing_plans_cta_button(...)`, `pricing_plans_auto_cta_url(...)`

Message customization:

- You can override copy globally via `config.message_builder`, which is used across limit checks and features. Suggested signature: `(context:, **kwargs) -> string` with contexts `:over_limit`, `:grace`, `:feature_denied`, and `:overage_report`.

- Current plan/limits for views:
  - `current_plan_name(billable)`, `plan_allows?(billable, feature)`, `plan_limit_remaining(billable, key)`, `plan_limit_percent_used(billable, key)`

#### Views: build a pricing plan table

- `PricingPlans.plans` (sorted sensible order)
- `PricingPlans.for_dashboard(billable)` / `PricingPlans.for_marketing`
- `PricingPlans.suggest_next_plan_for(billable, keys: ...)`
- `PricingPlans.decorate_for_view(plan, ...)`

#### Views: build plan warning messages

- `PricingPlans::OverageReporter.report_with_message(billable, target_plan_key)` -- Overage reporting for downgrade UX

## Using with `pay` and/or `usage_credits`

`pricing_plans` is designed to work seamlessly with other complementary popular gems like `pay` (to handle actual subscriptions and payments), and `usage_credits` (to handle credit-like spending and refills)

### Using `pricing_plans` with the `pay` gem
TODO

### Using `pricing_plans` with the `usage_credits` gem

    Some per-period limits are not a currency and shouldn’t be purchasable: e.g., “Create up to 3 custom AI models per month”, “1 domain change per week”, “2 exports/day”. Those are discrete allowances, not metered workloads. Credits are a bad fit (you don’t want to sell “custom-model tokens”).

    For classic metered workloads (API calls, image generations, tokenized compute), use credits.

So the clean separation:

Golden rule

    pricing_plans handles:

        Booleans (feature flags).

        Persistent caps (max concurrent resources: products, seats, projects).

        Discrete per-period allowances (rare; e.g., “3 custom models / month”), with no overage purchasing by default (you can still choose to allow overage via credits—see below).

    usage_credits handles:

        Metered consumption (API calls, generations, storage GB*hrs, etc.).

        Included monthly credits via subscription plans.

        Top-ups and pay-as-you-go.

        Rollover/expire semantics and the entire ledger.

If a dimension is metered and you want to sell overage/top-ups → credits only. Don’t also define a periodic limit for the same dimension in pricing_plans. We’ll actively lint and refuse dual definitions at boot.


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


TODO: complete the readme