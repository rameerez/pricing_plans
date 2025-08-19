# Model helpers and methods

## Define your `Enforceable` class

Your `Enforceable` class is the class on which plan limits are enforced.

It's usually the same class that gets charged for a subscription, the class that gets billed, the class that "owns" the plan, the class with the `pay_customer` if you're using Pay, etc. It's usually: `User`, `Organization`, `Team`, etc.

To define your `Enforceable` class, just add the model mixin:

```ruby
class User < ApplicationRecord
  include PricingPlans::Enforceable
end
```

## Link plan limits to your `Enforceable` model

Now you can link any `has_many` relationships in this model to `limits` defined in your `pricing_plans.rb`

For example, if you defined a `:projects` limit like this:

```ruby
plan :pro do
  limits :projects, to: 5
end
```

Then you can link the `:projects` limit to any `has_many` relationship on the `Enforceable` model (`User`, in this example):

```ruby
class User < ApplicationRecord
  include PricingPlans::Enforceable

  has_many :projects, limited_by_pricing_plans: true
end
```

The `:limited_by_pricing_plans` part infers that the association name (`:projects`) is the same as the limit key you defined on `pricing_plans.rb`. If that's not the case, you can make the association explicit:

```ruby
class User < ApplicationRecord
  include PricingPlans::Enforceable

  has_many :custom_projects, limited_by_pricing_plans: { limit_key: :projects }
end
```

In general, you can omit the limit key when it can be inferred from the model (e.g., `Project` → `:projects`).

`limited_by_pricing_plans` plays nicely with every other ActiveRecord validation you may have in your relationship:

```ruby
class User < ApplicationRecord
  include PricingPlans::Enforceable

  has_many :projects, limited_by_pricing_plans: true, dependent: :destroy
end
```

You can also customize the validation error message by passing `error_after_limit`. This error message behaves like other ActiveRecord validation, and will get attached to the record upon failed creation:

```ruby
class User < ApplicationRecord
  include PricingPlans::Enforceable

  has_many :projects, limited_by_pricing_plans: { error_after_limit: "Too many projects!" }, dependent: :destroy
end
```


## Enforce limits in your `Enforceable` class

The `Enforceable` class (the class to which you add the `include PricingPlans::Enforceable` mixin) automatically gains these helpers to check limits:

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


## Gate features in your `Enforceable` class

You can also check for feature flags like this:

```ruby
user.plan_allows?(:api_access)               # => true/false
```

Of course, there's also dynamic syntactic sugar of the form `plan_allows_<feature_key>?`, like this:

```ruby
user.plan_allows_api_access?
```


## Other helpers and methods

### Aggregates

If you want to get an aggregate across multiple keys instead of checking them individually:
```ruby
# Aggregates across keys
user.any_grace_active_for?(:products, :activations)
user.earliest_grace_ends_at_for(:products, :activations)
```

### Check and override plans

You can also check and override the current pricing plan for any user, which comes handy as an admin:
```ruby
user.current_pricing_plan                    # => PricingPlans::Plan
user.assign_pricing_plan!(:pro)              # manual assignment override
user.remove_pricing_plan!                    # remove manual override (fallback to default)
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
