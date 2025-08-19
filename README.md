# 💵 `pricing_plans` - Define and enforce pricing plan limits in your Rails app

[![Gem Version](https://badge.fury.io/rb/pricing_plans.svg)](https://badge.fury.io/rb/pricing_plans)

Enforce pricing plan limits with one-liners that read like plain English. Stop scattering and entangling pricing logic everywhere in your Rails SaaS.

For example, this is how you **define plans** and their entitlements:
```ruby
plan :pro do
  allows :api_access
  limits :projects, to: 5
end
```

Then, you can **gate features** in your controllers:
```ruby
before_action :enforce_api_access!, only: [:create]
```

And check anywhere in your app to hide / show UI:
```ruby
@user.plan_allows_api_access?  # => true / false
@user.projects_remaining       # => 2
```

`pricing_plans` is your single source of truth for pricing plans, so you can use it to [build pricing pages and paywalls](#views-build-pricing-pages-paywalls-pricing-tables-usage-indicators-conditional-buttons) too.

The gem works standalone, and it also plugs nicely into popular gems: it works seamlessly out of the box with [`pay`](https://github.com/pay-rails/pay) and [`usage_credits`](https://github.com/rameerez/usage_credits/). More info [here](#using-with-pay-andor-usage_credits).

## Quickstart

Add this to your Gemfile:

```ruby
gem "pricing_plans"
```

Then install the gem:

```bash
bundle install
```

After that, generate and run [the required migration](#why-the-models):

```bash
rails g pricing_plans:install
rails db:migrate
```

This will also create a `config/initializers/pricing_plans.rb` file where you need to [define your pricing plans](docs/01-define-pricing-plans.md).

Then, just add the model mixin to the actual model on which limits should be enforced, like: `User`, `Organization`, etc.:

```ruby
class User < ApplicationRecord
  include PricingPlans::Enforceable
end
```

This mixin will automatically give your model the [helpers and methods](#model-helpers) you can use to consistently enforce check and enforce limits:
```ruby
class User < ApplicationRecord
  include PricingPlans::Enforceable

  has_many :projects, limited_by_pricing_plans: { error_after_limit: "Too many projects!" }, dependent: :destroy
end
```

You also get [controller helpers](#controller-helpers):

```ruby
```

methods to check limits in your views for conditional UI. Check the [full API reference](#available-methods--full-api-reference).


## What `pricing_plans` does and doesn't do

`pricing_plans` handles pricing plan entitlements; that is: what a user can and can't access based on their current SaaS plan.

Some other features you may like:
 - Grace periods (hard & soft caps for limits)
 - Customizable downgrade behavior for overage handling
 - Row-level locks to prevent race conditions on quota enforcement

Here's what `pricing_plans` **does not** handle:
  - Payment processing / billing (that's [`pay`](https://github.com/pay-rails/pay) or Stripe's responsibility)
  - Price definition / currency handling (that's Stripe / payment processor)
  - Usage credits / metered usage (that's [`usage_credits`](https://github.com/rameerez/usage_credits/)'s responsibility)
  - Feature flags for A/B testing or staged rollouts (that's `flipper`)
  - User roles, authorization, or per-user permissions (that's `cancancan` or `pundit`)

## 🤔 Why this gem exists

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

Enforcing pricing plan limits in code (through entitlements, usage quotas, and feature gating) is tedious and painful plumbing. Every SaaS needs to check whether users can perform an action based on the plan they're currently subscribed to, but it often leads to brittle, scattered, unmaintainable pricing logic that gets entangled with core application code, opening gaps for under-enforcement and leaving money on the table.

Integrating payment processing (Stripe, `pay`, etc.) is relatively straightforward, but enforcing actual plan limits (ensure users only get the features and usage their tier allows) is a whole different task. It's the kind of plumbing no one wants to do. Founders often put their focus on capturing the payment, and then default to a "poor man's" implementation of per-plan entitlements. Maintaining these in-house DIY solutions is a huge time sink, and engineers often can't keep up with constant pricing or packaging changes.

`pricing_plans` aims to offer a centralized, single-source-of-truth way of defining & handling pricing plans, so you can enforce plan limits with reusable helpers that read like plain English.


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

## Testing

We use Minitest for testing. Run the test suite with `bundle exec rake test`

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/pricing_plans. Our code of conduct is: just be nice and make your mom proud of what you do and post online.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
