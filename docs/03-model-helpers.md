# Model helpers and methods

## Define your `PlanOwner` class

Your `PlanOwner` class is the class on which plan limits are enforced.

It's usually the same class that gets charged for a subscription, the class that gets billed, the class that "owns" the plan, the class with the `pay_customer` if you're using Pay, etc. It's usually: `User`, `Organization`, `Team`, etc.

To define your `PlanOwner` class, just add the model mixin:

```ruby
class User < ApplicationRecord
  include PricingPlans::PlanOwner
end
```

By adding the `PricingPlans::PlanOwner` mixin to a model, you automatically get all the features described below.

## Link plan limits to your `PlanOwner` model

Now you can link any `has_many` relationships in this model to `limits` defined in your `pricing_plans.rb`

For example, if you defined a `:projects` limit like this:

```ruby
plan :pro do
  limits :projects, to: 5
end
```

Then you can link the `:projects` limit to any `has_many` relationship on the `PlanOwner` model (`User`, in this example):

```ruby
class User < ApplicationRecord
  include PricingPlans::PlanOwner

  has_many :projects, limited_by_pricing_plans: true
end
```

The `:limited_by_pricing_plans` part infers that the association name (`:projects`) is the same as the limit key you defined on `pricing_plans.rb`. If that's not the case, you can make the association explicit:

```ruby
class User < ApplicationRecord
  include PricingPlans::PlanOwner

  has_many :custom_projects, limited_by_pricing_plans: { limit_key: :projects }
end
```

In general, you can omit the limit key when it can be inferred from the model (e.g., `Project` → `:projects`).

`limited_by_pricing_plans` plays nicely with every other ActiveRecord validation you may have in your relationship:

```ruby
class User < ApplicationRecord
  include PricingPlans::PlanOwner

  has_many :projects, limited_by_pricing_plans: true, dependent: :destroy
end
```

You can also customize the validation error message by passing `error_after_limit`. This error message behaves like other ActiveRecord validation, and will get attached to the record upon failed creation:

```ruby
class User < ApplicationRecord
  include PricingPlans::PlanOwner

  has_many :projects, limited_by_pricing_plans: { error_after_limit: "Too many projects!" }, dependent: :destroy
end
```


## Enforce limits in your `PlanOwner` class

The `PlanOwner` class (the class to which you add the `include PricingPlans::PlanOwner` mixin) automatically gains these helpers to check limits:

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

If you want to get an aggregate of graces across multiple keys instead of checking them individually:
```ruby
# Aggregates across keys
user.any_grace_active_for?(:products, :activations)
user.earliest_grace_ends_at_for(:products, :activations)
```

## Gate features in your `PlanOwner` class

You can also check for feature flags like this:

```ruby
user.plan_allows?(:api_access)               # => true/false
```

Of course, there's also dynamic syntactic sugar of the form `plan_allows_<feature_key>?`, like this:

```ruby
user.plan_allows_api_access?
```

## Usage and limits status

Checking the current usage with respect to plan limits comes in handy, especially when [building views](/docs/04-views.md). The following methods are useful to build warning / alert snippets, upgrade prompts, usage trackers, etc.

### `limit`: Check a single limit

You can check the status of a single limit with `user.limit(:projects)`

This always returns a single `StatusItem`, which represents one status item for a limit. For example, output for `user.limit(:projects)`:

```ruby
#<struct
  key=:projects,
  human_key="projects",
  current=1,
  allowed=1,
  percent_used=100.0,
  grace_active=false,
  grace_ends_at=nil,
  blocked=true,
  per=false,
  severity=:at_limit,
  severity_level=2,
  message="You’ve reached your limit for projects (1/1). Upgrade your plan to unlock more.",
  overage=0,
  configured=true,
  unlimited=false,
  remaining=0,
  after_limit=:block_usage,
  :attention?=true,
  :next_creation_blocked?=true,
  warn_thresholds=[0.6, 0.8, 0.95],
  next_warn_percent=nil,
  period_start=nil,
  period_end=nil,
  period_seconds_remaining=nil
>
```

#### The `StatusItem` object

As you can see, the `StatusItem` object returns a bunch of useful information for that limit. Something that may have caught your attention is `severity` and `severity_level`. For each limit, `pricing_plans` computes severity, to help you better organize and display warning messages / alerts to your users.

Severity order: `:blocked` > `:grace` > `:at_limit` > `:warning` > `:ok`

Their corresponding `severity_level` are: `4`, `3`, `2`, `1`, `0`; respectively.

Each severity comes with a default **title**:
  - `blocked`: "Cannot create more resources"
  - `grace`: "Limit Exceeded (Grace Active)"
  - `at_limit`: "At Limit"
  - `warning`: "Approaching Limit"
  - `ok`: `nil`
  
Each severity Messages come from your `config.message_builder` in [`pricing_plans.rb`](/docs/01-define-pricing-plans.md) when present; otherwise we provide sensible defaults:
  - `blocked`: "Cannot create more <key> on your current plan."
  - `grace`: "Over the <key> limit, grace active until <date>."
  - `at_limit`: "You are at <current>/<limit> <key>. The next will exceed your plan."
  - `warning`: "You have used <current>/<limit> <key>."
  - `ok`: `nil`

### `limits`: Get the status of all limits

You can call `user.limits` (plural, no arguments) to get the current status of all limits. You will get an array of `StatusItem` objects, with the same keys as described above.

Sample output:

```ruby
user.limits

# => [
#  #<struct key=:limit_1...>,
#  #<struct key=:limit_2...>,
#  #<struct key=:limit_3...>
# ]
```

Of course, prefer `user.limit(:key)` (singular, one argument) when you only need a the status of a single limit.

You can also filter which limits you get status items for, by passing their limits keys as arguments:

```ruby
user.limits(:projects, :posts)
```


### `limits_overview`: Get a summary of all limits

`limits_overview` is a thin wrapper around `limits` that, on top of returning the array of `StatusItem` objects, returns you a few "overall helpers" that can help you let the user know the overall status of their plan usage in a single view.

`limits_overview` returns a JSON containing:
  - `severity`: highest severity out of all limits
  - `severity_level` corresponding severity level
  - `title`: overall severity title
  - `message`: overall severity message
  - `attention?`: whether overall limits require user attention or not
  - `keys`: array of all computed limits keys
  - `highest_keys`: array of limits keys with the highest severity
  - `highest_limits`: array of `StatusItem`
  - `keys_sentence`: limit keys requiring attention, in a readable sentence

For example:

```ruby
user.limits_overview
```

Would output:

```ruby
{
  severity: :at_limit,
  severity_level: 2,
  title: "At your plan limit",
  message: "You have reached your plan limit for products.",
  attention?: true,
  keys: [:products, :licenses, :activations],
  highest_keys: [:products],
  highest_limits: [
    #<struct key=:projects...>
  ],
  keys_sentence: "products",
  noun: "plan limit",
  has_have: "has",
  cta_text: "View Plans",
  cta_url: nil
} 
```

Of course, you can also pass limit keys as arguments to filter the output, like: `user.limits_overview(:projects, :posts)`

### Limits aggregates

If you only want to get the overall severity of message of all keys, you can do:

```ruby
user.limits_severity(:projects, :posts)           # => :ok | :warning | :at_limit | :grace | :blocked
user.limits_message(:projects, :posts)            # => String (combined human message string) or `nil`
```

Additional per-limit checks:

```ruby
user.limit_overage(:projects)                     # => Integer (0 if within)
user.limit_alert(:projects)                       # => { visible?: true/false, severity:, title:, message:, overage:, cta_text:, cta_url: }
```

You also get these handy helpers:

```ruby
user.attention_required_for_limit?(:projects)     # => true | false` (alias for any of warning/grace/blocked)
user.approaching_limit?(:projects, at: 0.9)       # => true | false` (uses highest `warn_at` if `at` omitted)
```

You can also use the top-level equivalents if you prefer: `PricingPlans.severity_for(user, :projects)` and friends.

## Other helpers and methods

### Check and override plans

You can also check and override the current pricing plan for any user, which comes handy as an admin:
```ruby
user.current_pricing_plan                    # => PricingPlans::Plan
user.assign_pricing_plan!(:pro)              # manual assignment override
user.remove_pricing_plan!                    # remove manual override (fallback to default)
```

### Misc

```ruby
user.on_free_plan?                           # => true/false
```

### `pay` integration

And finally, you get very thin convenient wrappers if you're using the `pay` gem:
```ruby
# Pay (Stripe) convenience (returns false/nil when Pay is absent)
# Note: this is billing-facing state, distinct from our in-app
# enforcement grace which is tracked per-limit.
user.pay_subscription_active?                # => true/false
user.pay_on_trial?                           # => true/false
user.pay_on_grace_period?                    # => true/false
```
