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

High level: you essentially need to do only two things:

- feature gating
- Check limits
two limits: count and feature gate

credits not included (require a ledger-like system)

connect with stripe ids monthly and yearly

## Usage: available methods & full API reference

Assuming you've correctly installed the gem and configured your pricing plans in `pricing_plans.rb` and your "billable" model (`User`, `Organization`, etc.) has the model mixin `include PricingPlans::Billable`, here's everything you can do:

### Models

#### Define your `Billable` class and add limits to your model

Your `Billable` class is the class on which limits are enforced. It's usually the same class that gets charged for a subscription, the class which "owns" the plan, etc. It's usually `User`, `Organization`, `Team`, etc.

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

You can also specify which controller helper `pricing_plans` should use globally in the `pricing_plans.rb` initializer:
```ruby
  config. ## TODO: do we have this? we should
  # from old docs: You can globally configure a resolver via `self.pricing_plans_billable_method = :current_organization` or `pricing_plans_billable { current_account }`.
  # Per-controller default `self.pricing_plans_redirect_on_blocked_limit = :pricing_path` (Symbol | String | Proc)
  #  but we need a global default too??
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
before_action { require_feature!(:api_access, on: :current_organization) }
```

#### Enforce plan limits in controllers

You can enforce limits for any action:
```ruby
before_action :enforce_projects_limit!, only: :create
```

As in feature gating, this is syntactic sugar (`enforce_<limit_key>_limit!`) that gets generated for every `limits` key in `pricing_plans.rb`. You can also use the primitive method:
```ruby
before_action { enforce_plan_limit!(:projects) }
```

And you can also pass a custom billable:
```ruby
before_action { enforce_projects_limit!(on: :current_organization) }
# or
before_action { enforce_plan_limit!(:projects, on: :current_organization) }
```

You can also specify a custom redirect path that will override the global config:
```ruby
before_action { enforce_plan_limit!(:projects, redirect_to: pricing_path) }
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


#### Set up a redirect when a feature is blocked or a limit is reached
g
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

### Build a pricing plan table
TODO

## Using with `pay` and/or `usage_credits`

`pricing_plans` is designed to work seamlessly with other complementary popular gems like `pay` (to handle actual subscriptions and payments), and `usage_credits` (to handle credit-like spending and refills)

### Using `pricing_plans` with the `pay` gem
TODO

### Using `pricing_plans` with the `usage_credits` gem
TODO

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