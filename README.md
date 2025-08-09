# 💵 pricing_plans — tiny, readable plans, features, and limits

pricing_plans is a very small plan catalog + enforcement brain for Rails apps. One Ruby file defines your plans; a couple of Ruby calls enforce limits and features. It aims to read like plain English and keep complexity off your plates.

## Install

Add to your Gemfile:

```ruby
gem "pricing_plans"
```

Then add the three tables and an initializer in your app (see tests for schema); or copy from below.

## Define your plans

Create `config/initializers/pricing_plans.rb`:

```ruby
PricingPlans.configure do |config|
  config.default_plan = :free

  config.plan :free do
    name        "Free"
    description "Enough to start"
    price       0

    limits  :projects, to: 1, after_limit: :grace_then_block, grace: 7.days
    limits  :custom_models, to: 0, per: :month
    disallows :api_access
  end

  config.plan :pro do
    price       29
    description "For growing teams"

    allows :api_access
    limits :projects,      to: 10, grace: 3.days
    limits :custom_models, to: 3,  per: :month
  end

  config.plan :enterprise do
    price_string "Contact"
    allows :api_access
    unlimited :projects, :custom_models
  end
end
```

## Model macro (explicit and simple)

Declare limits on the child record, stating which association is the billable. No magic inference.

```ruby
class Project < ApplicationRecord
  belongs_to :organization
  include PricingPlans::Limitable
  limited_by_pricing_plans :projects, billable: :organization
end

class CustomModel < ApplicationRecord
  belongs_to :organization
  include PricingPlans::Limitable
  limited_by_pricing_plans :custom_models, billable: :organization, per: :month
end
```

## Billable helpers (callable on billable instances)

```ruby
org.current_pricing_plan                    # => PricingPlans::Plan
org.plan_allows?(:api_access)               # => true/false
org.within_plan_limits?(:projects, by: 1)   # => true/false
org.plan_limit_remaining(:projects)         # => integer or :unlimited
org.plan_limit_percent_used(:projects)      # => Float percent
org.grace_active_for?(:projects)            # => true/false
org.plan_blocked_for?(:projects)            # => true/false
org.assign_pricing_plan!(:pro)              # manual override
org.remove_pricing_plan!
```

## Controllers / services — explicit, minimal API

Use the two primitives anywhere:

```ruby
result = PricingPlans::ControllerGuards.require_plan_limit!(
  :projects,
  billable: current_organization,
  by: 1
)
case
when result.ok?      then # proceed
when result.warning? then flash[:warning] = result.message
when result.grace?   then flash[:warning] = result.message
when result.blocked? then render status: :forbidden, json: { error: result.message }
end
```

```ruby
# Feature gate
PricingPlans::ControllerGuards.require_feature!(:api_access, billable: current_organization)
```

If you need to proceed in trusted flows while marking state:

```ruby
result = PricingPlans::ControllerGuards.require_plan_limit!(
  :projects,
  billable: org,
  allow_system_override: true
)
# proceed; inspect result.metadata[:system_override]
```

## Periods and grace

- Persistent caps count live rows.
- Per-period limits increment a usage row within the current window.
- `:after_limit` is one of `:grace_then_block`, `:block_usage`, `:just_warn`.

## What we don’t do

- No dynamic before_action helpers.
- No controller auto-rescues.
- No association inference. Always specify `billable:`.
- No generators (keep it tiny). Copy the schema from tests or your own migration.

## Public surface

- Plans: `PricingPlans.plans`, `PricingPlans.for_dashboard(billable)`, `PricingPlans.for_marketing`.
- Plan resolution: `PricingPlans::PlanResolver.effective_plan_for(billable)`.
- Enforcement: `PricingPlans::ControllerGuards.require_plan_limit!(...)`, `require_feature!`.
- Model macro: `limited_by_pricing_plans :key, billable: :association, per: nil|:month|:week|:day`.
- Overage report: `PricingPlans::OverageReporter.report_with_message(billable, :free)`.

MIT
