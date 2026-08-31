# 💵 `pricing_plans` - Define and enforce pricing plan limits in your Rails app (SaaS entitlements)

[![Gem Version](https://badge.fury.io/rb/pricing_plans.svg)](https://badge.fury.io/rb/pricing_plans) [![Build Status](https://github.com/rameerez/pricing_plans/workflows/Tests/badge.svg)](https://github.com/rameerez/pricing_plans/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=pricing_plans)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=pricing_plans)!

`pricing_plans` allows you to enforce pricing plan limits with one-liners that read like plain English. Avoid scattering and entangling pricing logic everywhere in your Rails SaaS.

For example, this is how you define pricing plans and their entitlements:
```ruby
plan :pro do
  allows :api_access      # Features: blocked by default unless explicitly allowed
  limits :projects, to: 5 # Limits: 0 by default unless a limit is set explicitly
end
```

Plans are **secure by default**: features are disabled and limits are set to 0 unless explicitly configured.

You can then gate features in your controllers:
```ruby
before_action :enforce_api_access!, only: [:create]
```

Do one-liner checks to hide / show conditional UI:

```ruby
<% if current_user.within_plan_limits?(:projects) %>
  ...
<% end %>
```

Or check limits and feature access anywhere in your app:

```ruby
@user.plan_allows_api_access?  # => true / false
@user.projects_remaining       # => 2
```

`pricing_plans` is your single source of truth for pricing plans, so you can use it to [build pricing pages and paywalls](/docs/04-views.md) too.

![pricing_plans Ruby on Rails gem - pricing table features](/docs/images/pricing_plans_ruby_rails_gem_pricing_table.jpg)


The gem works standalone, and it also plugs nicely into popular gems: it works seamlessly out of the box if you're already using [`pay`](https://github.com/pay-rails/pay) or [`usage_credits`](https://github.com/rameerez/usage_credits/). More info [here](/docs/06-gem-compatibility.md).

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

Then, just add the model mixin to the plan owner, that is: the actual model on which limits should be enforced (`User`, `Organization`, etc.):

```ruby
class User < ApplicationRecord
  include PricingPlans::PlanOwner
end
```

This mixin will automatically give your plan owner model the [model helpers and methods](/docs/03-model-helpers.md) you can use to consistently check and enforce limits:
```ruby
class User < ApplicationRecord
  include PricingPlans::PlanOwner

  has_many :projects, limited_by_pricing_plans: { error_after_limit: "Too many projects for your plan!" }, dependent: :destroy
end
```

You also get [controller helpers](/docs/02-controller-helpers.md):

```ruby
before_action { gate_feature!(:api_access) }

# or with syntactic sugar:

before_action :enforce_api_access!
```

And you also get a lot of [view helpers and methods](/docs/04-views.md) to check limits in your views for conditional UI, and to build usage meters, usage warnings, and a handful of other useful UI components.

![pricing_plans Ruby on Rails gem - pricing plan usage meter](/docs/images/pricing_plans_ruby_rails_gem_usage_meter.jpg)

You can also display upgrade alerts to prompt users into upgrading to the next plan when they're near their plan limits:

![pricing_plans Ruby on Rails gem - pricing plan upgrade prompt](/docs/images/pricing_plans_ruby_rails_gem_usage_alert_upgrade.jpg)

You can attach arbitrary plan `metadata` for UI/presentation needs (icons, colors, badges) directly in the initializer:

```ruby
plan :hobby do
  metadata icon: "rocket", color: "bg-red-500"
end

plan.metadata[:icon] # => "rocket"
```

You can also grandfather users into old plans (hidden to other users), assign plans manually without requiring a payment (for testing, gifts, or employees), and much more!

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

- `PricingPlans::Assignment` stores explicit pricing plan overrides independently of the billing system. This is useful for gifts, employee access, demos, support interventions, and grandfathered customers.
  - What: A `plan_key` and a required provenance label such as `"admin"`, `"customer_success_gift"`, or `"legacy_import"`. There can be only one override per plan owner.
  - How it's used: `PlanResolver` checks explicit override → Pay subscription → configured default. Every persisted override takes precedence over subscription-based plans, including an override whose key happens to equal the configured default.
  - Intention-revealing API: call `plan_owner.override_pricing_plan!(:pro, source: "admin")` to create or update an override, and `plan_owner.clear_pricing_plan_override!` to resume normal subscription/default resolution.
  - Provenance helpers: `pricing_plan_overridden?`, `pricing_plan_override`, and `pricing_plan_override_source` expose the override directly. `current_pricing_plan_resolution` preserves both entitlement and billing context when an override and a subscription coexist.

An ordinary free/default account needs no assignment row:

```ruby
# Intentional exception: pin this organization to Pro independently of billing.
organization.override_pricing_plan!(:pro, source: "customer_success_gift")

# Resume automatic Pay subscription / configured default resolution.
organization.clear_pricing_plan_override!
```

The old `assign_pricing_plan!` and `remove_pricing_plan!` names are deprecated because they hide the override semantics. See [Check and explicitly override plans](docs/03-model-helpers.md#check-and-explicitly-override-plans) for migration and strict-mode guidance.

- `PricingPlans::EnforcementState` tracks per-plan_owner per-limit enforcement state for persistent caps and per-period allowances (grace/warnings/block state) in a race-safe way.
  - What: `exceeded_at`, `blocked_at`, last warning info, and a small JSON `data` column where we persist plan-derived parameters like grace period seconds.
  - How it’s used: When you exceed a limit, we upsert/read this row under row-level locking to start grace, compute when it ends, flip to blocked, and to ensure idempotent event emission (`on_warning`, `on_grace_start`, `on_block`).

- `PricingPlans::Usage` tracks per-period allowances (e.g., “3 projects per month”). Persistent caps don’t need a table because they are live counts.
  - What: `period_start`, `period_end`, and a monotonic `used` counter with a last-used timestamp.
  - How it’s used: On create of the metered model, we increment or upsert the usage for the current window (based on `PeriodCalculator`). Reads power `remaining`, `percent_used`, and warning thresholds.

## Gem features

Enforcing pricing plans is one of those boring plumbing problems that look easy from a distance but get complex when you try to engineer them for production usage. The poor man's implementation of nested ifs shown in the example above only get you so far, you soon start finding edge cases to consider. Here's some of what we've covered in this gem:

- Safe under load: we use row locks and retries when setting grace/blocked/warning state, and we avoid firing the same event twice. See [grace_manager.rb](lib/pricing_plans/grace_manager.rb).

- Self-healing state: when usage drops below the limit (e.g., user deletes resources, upgrades plan, or reduces usage), stale exceeded/blocked flags are automatically cleared. Methods like `grace_active?` and `should_block?` will clear outdated enforcement state as a side effect. This prevents users from remaining incorrectly flagged after remediation.

- Accurate counting: persistent limits count live current rows (using `COUNT(*)`, make sure to index your foreign keys to make it fast at scale); per‑period limits record usage for the current window only. You can filter what counts with `count_scope` (Symbol/Hash/Proc/Array), and plan settings override model defaults. See [limitable.rb](lib/pricing_plans/limitable.rb) and [limit_checker.rb](lib/pricing_plans/limit_checker.rb).

- Clear rules: default is to block when you hit the cap; grace periods are opt‑in. In status/UI, 0 of 0 isn’t shown as blocked. See [plan.rb](lib/pricing_plans/plan.rb), [grace_manager.rb](lib/pricing_plans/grace_manager.rb), and [view_helpers.rb](lib/pricing_plans/view_helpers.rb).

- Semantic enforcement: for `grace_then_block`, grace periods start when usage goes *over* the limit (e.g., 6/5), not when it *reaches* the limit (5/5). This allows users to use their full allocation before grace begins. For `block_usage`, blocking occurs at or over the limit (e.g., at 5/5, the next creation is blocked).

- Simple controllers: one‑liners to guard actions, predictable redirect order (per‑call → per‑controller → global → pricing_path), and an optional central handler. See [controller_guards.rb](lib/pricing_plans/controller_guards.rb).

- Billing‑aware periods: supports billing cycle (when Pay is present), calendar month/week/day, custom time windows, and durations. See [period_calculator.rb](lib/pricing_plans/period_calculator.rb).


## Downgrades and overages

When a customer moves to a lower plan (via Stripe/Pay or an explicit override), the new plan’s limits start applying immediately. Existing resources are never auto‑deleted by the gem; instead:

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

## Changing your pricing: grandfathering and feature grants

Sooner or later you'll reprice: a feature that used to be on a cheap plan moves to a higher one. The customers who already pay you should keep what they signed up for — and that should not require new columns, backfills, or rake tasks in your app. (Full guide: [docs/07-repricing.md](/docs/07-repricing.md).)

### Grandfathering (declarative, zero state)

Remove the feature from the plan's `allows`, and declare the grandfather right next to it:

```ruby
plan :indie do
  allows :api_access                 # :distribution moved to :starter on 2026-08-31
  grandfather :distribution, subscribed_before: "2026-09-01"
end
```

That's the whole migration. Owners whose tenure on the plan began before the cutoff keep the feature; everyone who arrives later doesn't. `plan_allows?(:distribution)` (and the `plan_allows_distribution?` sugar) just keep working everywhere — the gate code in your app doesn't change at all. Your initializer stays the single, git-versioned record of what changed and when.

Semantics, precisely:

- **Tenure** is when the owner's current subscription (or manual plan assignment) was created — the older of the two if both exist, so a support-added assignment can never strip an entitlement the subscription already earned.
- Grandfathering **rides a continuous subscription**: cancel and come back later, and you re-enter at current pricing (the industry-standard deal). For a promise that must survive anything, use a grant (below).
- Cutoffs accept a `Time`, `Date`, or `String`; date-only values are read as **midnight UTC**.
- Declaring `grandfather` for a feature the plan still `allows` raises a configuration error — one of the two lines is a mistake.

### Feature grants (per-owner exceptions)

For individual exceptions — comps, beta access, sales promises, support remediation, or a grandfather that must survive cancellation — grant the feature to the owner directly:

```ruby
org.grant_feature!(:distribution, source: "founder_comp", note: "conference friend")
org.grant_feature!(:sso, source: "sales", expires_at: 30.days.from_now)

org.plan_allows?(:sso)                      # => true (source-aware predicate below)
org.feature_entitlement_source(:sso)        # => :plan | :grandfather | :grant | nil
org.feature_granted?(:sso)                  # => true (active grant row exists)

org.revoke_feature!(:sso, note: "eval over") # keeps the row, stamps revoked_at
org.feature_grants                           # full audit trail, revocations included
```

Grants live in the `pricing_plans_feature_grants` table (created by the install generator; apps upgrading from < 0.6.0 add it with `rails generate pricing_plans:grants && rails db:migrate`). They attach to the owner, not the plan, so they survive plan changes and cancellations until you revoke them. Rows are never deleted by the API: revoking stamps `revoked_at`, so "why does this customer have this?" always has an answer.

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

We use Minitest for testing. Run the test suite with:

```bash
bundle exec rake test
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/pricing_plans. Our code of conduct is: just be nice and make your mom proud of what you do and post online.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
