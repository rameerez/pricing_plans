# 💵 `pricing_plans` - Define and enforce pricing plan limits in your Rails app

[![Gem Version](https://badge.fury.io/rb/pricing_plans.svg)](https://badge.fury.io/rb/pricing_plans)

Enforce pricing plan limits with one-liners that read like plain English. Avoid scattering and entangling pricing logic everywhere in your Rails SaaS.

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

`pricing_plans` is your single source of truth for pricing plans, so you can use it to [build pricing pages and paywalls](/docs/04-views.md) too.

The gem works standalone, and it also plugs nicely into popular gems: it works seamlessly out of the box with [`pay`](https://github.com/pay-rails/pay) and [`usage_credits`](https://github.com/rameerez/usage_credits/). More info [here](/docs/06-gem-compatibility.md).

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

This will also create a `config/initializers/pricing_plans.rb` file where you need to [define your pricing plans](/docs/01-define-pricing-plans.md).

Then, just add the model mixin to the actual model on which limits should be enforced (the plan owner), like: `User`, `Organization`, etc.:

```ruby
class User < ApplicationRecord
  include PricingPlans::PlanOwner
end
```

This mixin will automatically give your model the [helpers and methods](/docs/03-model-helpers.md) you can use to consistently enforce check and enforce limits:
```ruby
class User < ApplicationRecord
  include PricingPlans::PlanOwner

  has_many :projects, limited_by_pricing_plans: { error_after_limit: "Too many projects for your plan!" }, dependent: :destroy
end
```

You also get [controller helpers](/docs/02-controller-helpers.md):

```ruby
```

methods to check limits in your views for conditional UI. Check the [full API reference](/docs/04-views.md).

## 🤓 Read the docs!

> [!IMPORTANT]  
> This gem has extensive docs. Please 👉 [read the docs here](/docs/01-define-pricing-plans.md) 👈

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
  - What: The arbitrary `plan_key` and a `source` label (default "manual"). Unique per plan_owner.
  - How it’s used: `PlanResolver` checks Pay → manual assignment → default plan. You can call `assign_pricing_plan!` and `remove_pricing_plan!` on the plan_owner.

- `PricingPlans::EnforcementState` tracks per-plan_owner per-limit enforcement state for persistent caps and per-period allowances (grace/warnings/block state) in a race-safe way.
  - What: `exceeded_at`, `blocked_at`, last warning info, and a small JSON `data` column where we persist plan-derived parameters like grace period seconds.
  - How it’s used: When you exceed a limit, we upsert/read this row under row-level locking to start grace, compute when it ends, flip to blocked, and to ensure idempotent event emission (`on_warning`, `on_grace_start`, `on_block`).

- `PricingPlans::Usage` tracks per-period allowances (e.g., “3 projects per month”). Persistent caps don’t need a table because they are live counts.
  - What: `period_start`, `period_end`, and a monotonic `used` counter with a last-used timestamp.
  - How it’s used: On create of the metered model, we increment or upsert the usage for the current window (based on `PeriodCalculator`). Reads power `remaining`, `percent_used`, and warning thresholds.

## Gem features

Enforcing pricing plans is one of those boring plumbing problems that look easy from a distance but get complex when you try to engineer them for production usage. The poor man's implementation of nested ifs shown in the example above only get you so far, you soon start finding edge cases to consider. Here's some of what we've covered in this gem:

- Safe under load: we use row locks and retries when setting grace/blocked/warning state, and we avoid firing the same event twice. See [grace_manager.rb](lib/pricing_plans/grace_manager.rb).

- Accurate counting: persistent limits count live current rows (using `COUNT(*)`, make sure to index your foreign keys to make it fast at scale); per‑period limits record usage for the current window only. You can filter what counts with `count_scope` (Symbol/Hash/Proc/Array), and plan settings override model defaults. See [limitable.rb](lib/pricing_plans/limitable.rb) and [limit_checker.rb](lib/pricing_plans/limit_checker.rb).

- Clear rules: default is to block when you hit the cap; grace periods are opt‑in. In status/UI, 0 of 0 isn’t shown as blocked. See [plan.rb](lib/pricing_plans/plan.rb), [grace_manager.rb](lib/pricing_plans/grace_manager.rb), and [view_helpers.rb](lib/pricing_plans/view_helpers.rb).

- Simple controllers: one‑liners to guard actions, predictable redirect order (per‑call → per‑controller → global → pricing_path), and an optional central handler. See [controller_guards.rb](lib/pricing_plans/controller_guards.rb).

- Billing‑aware periods: supports billing cycle (when Pay is present), calendar month/week/day, custom time windows, and durations. See [period_calculator.rb](lib/pricing_plans/period_calculator.rb).


## Downgrades and overages

When a customer moves to a lower plan (via Stripe/Pay or manual assignment), the new plan’s limits start applying immediately. Existing resources are never auto‑deleted by the gem; instead:

- **Persistent caps** (e.g., `:projects, to: 3`): We count live rows. If the account is now over the new cap, creations will be blocked (or put into grace/warn depending on `after_limit`). Users must remediate by deleting/archiving until under cap.
- 
- **Per‑period allowances** (e.g., `:custom_models, to: 3, per: :month`): The current window’s usage remains as is. Further creations in the same window respect the downgraded allowance and `after_limit` policy. At the next window, the allowance resets.

Use `OverageReporter` to present a clear remediation UX before or after applying a downgrade:

```ruby
report = PricingPlans::OverageReporter.report_with_message(org, :free)
if report.items.any?
  flash[:alert] = report.message
  # report.items -> [#<OverageItem limit_key:, kind: :persistent|:per_period, current_usage:, allowed:, overage:, grace_active:, grace_ends_at:>]
end
```

Example human message:
- "Over target plan on: projects: 12 > 3 (reduce by 9), custom_models: 5 > 0 (reduce by 5). Grace active — projects grace ends at 2025-01-06T12:00:00Z."

Notes:
- If you provide a `config.message_builder`, it’s used to customize copy for the `:overage_report` context.
- This reporter works regardless of whether any controller/model action has been hit; it reads live counts and current period usage.

### Override checks

Some times you'll want to override plan limits / feature gating checks. A common use case is if you're responding to a webhook (like Stripe), you'll want to process the webhook correctly (bypassing the check) and maybe later handle the limit manually.

To do that, you can use `require_plan_limit!`. An example to proceed but mark downstream:

```ruby
def webhook_create
  result = require_plan_limit!(:projects, plan_owner: current_organization, allow_system_override: true)

  # Your custom logic here.
  # You could proceed to create; inspect result.grace?/warning? and result.metadata[:system_override]
  Project.create!(metadata: { created_during_grace: result.grace? || result.warning?, system_override: result.metadata[:system_override] })

  head :ok
end
```

Note: model validations will still block creation even with `allow_system_override` -- it's just intended to bypass the block on controllers.

## Testing

We use Minitest for testing. Run the test suite with `bundle exec rake test`

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/pricing_plans. Our code of conduct is: just be nice and make your mom proud of what you do and post online.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
