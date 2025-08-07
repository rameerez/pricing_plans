# 💵 `pricing_plans` - Define and enforce pricing plan limits in your Rails app

[![Gem Version](https://badge.fury.io/rb/pricing_plans.svg)](https://badge.fury.io/rb/pricing_plans)

`pricing_plans` is the single source of truth for pricing plans and plan limits in your Rails apps. It provides methods you can use across your app to consistently check whether users can perform an action based on the plan they're subscribed to.

Define plans and their limits like:
```ruby
plan :pro do
  limits :posts, to: 5.max
  allows :api_access
end
```

Then, in your controller, you can easily check and gate features:
```ruby
before_action :enforce_api_access!, only: [:show] # or something like this. I'm thinking generating enforce_* methods where * is the values of any of the `allows` fields. This controller line should be self-explainatory and read like plain English. Should play natively and seamlessly with Rails 8+ and the rest of the expected arguments etc.
```

And, in your models, you can check models stay within plan limits:
```ruby
class Post < ApplicationRecord
  limited_by_pricing_plans # SIMPLIFIED! Renamed this, should auto-mixin with all necessary things. It should be dead simple and read like plain english. Should this accept more params? Reason and argue through it. Assume the thing limited is the model name, match by model name to the thing defined in the plan block, pass an optional argument if you wanna make it explicit or make explicit the billable etc only if you cannot infer it or if there's ambiguitiy -- also, allow to pass custom params like a custom error message etc
end
```


`pricing_plans` helps you stop reimplementing feature gating and duplicating code across your entire codebase.


---
---

HUMAN REVISIONS ONLY UNTIL HERE!!!! EVERYTHING BELOW IS **NOT** UPDATED AND CORRESPONDS TO THE PREVIOUS, DATED VERSION OF THE README THAT STILL NEEDS TO BE REWRITTEN

---
---

In **one Ruby file**, you define:

- **Plans** (name, description, bullets, Stripe price link, optional display price)
- **Feature flags** (booleans)  
- **Limits** with **grace_then_block** behavior by default:
  - **Persistent caps** (max concurrent things: projects, seats, models)
  - **Discrete per-period allowances** (rare, e.g., "3 custom models / month")
- **Events** (warning, grace start, block) so you can email/notify

**Perfect for:** Rails teams using **Stripe via Pay** who are tired of re-implementing plan gates in controllers, policies, and views.

## 🚀 Quick Start

Add to your Gemfile:

```ruby
gem 'pricing_plans'
```

Then run:

```bash
bundle install
rails generate pricing_plans:install
rails db:migrate
```

## 📖 Usage

### 1. Define Your Plans

Edit `config/initializers/pricing_plans.rb`:

```ruby
PricingPlans.configure do |config|
  config.billable_class = "Organization"  # or "User", "Account", etc.
  config.default_plan = :free
  config.highlighted_plan = :pro
  config.period_cycle = :billing_cycle

  plan :free do
    name "Free"
    description "Perfect for getting started"
    price 0
    bullets "Basic features", "Community support"
    
    limits :projects, to: 1.max, after_limit: :grace_then_block, grace: 10.days
    disallows :api_access
  end

  plan :pro do
    stripe_price "price_pro_monthly_29"
    name "Pro"
    bullets "Advanced features", "API access", "Priority support"
    
    allows :api_access
    limits :projects, to: 25.max
    unlimited :team_members
    
    # Optional: show included credits (requires usage_credits gem)
    includes_credits 1_000, for: :api_calls
  end

  # Event handlers for notifications
  config.on_warning :projects do |billable, threshold|
    PlanMailer.quota_warning(billable, :projects, threshold).deliver_later
  end

  config.on_grace_start :projects do |billable, grace_ends_at|
    PlanMailer.grace_started(billable, :projects, grace_ends_at).deliver_later
  end

  config.on_block :projects do |billable|
    PlanMailer.blocked(billable, :projects).deliver_later
  end
end
```

### 2. Add Limitable to Your Models

```ruby
class Project < ApplicationRecord
  belongs_to :organization
  include PricingPlans::Limitable
  limited_by_pricing_plans :projects, billable: :organization  # persistent cap
end

# For discrete per-period allowances:
class CustomModel < ApplicationRecord
  belongs_to :organization
  include PricingPlans::Limitable
  limited_by_pricing_plans :custom_models, billable: :organization, per: :month
end
```

### 3. Use Controller Guards

```ruby
class ProjectsController < ApplicationController
  before_action :check_project_limit, only: [:create]

  def create
    # Your creation logic here
  end

  private

  def check_project_limit
    result = require_plan_limit! :projects, billable: current_organization
    return redirect_to(pricing_path, alert: result.message) if result.blocked?
    flash[:warning] = result.message if result.warning?
  end
end

class ApiController < ApplicationController
  before_action :require_api_access

  private

  def require_api_access
    require_feature! :api_access, billable: current_organization
  end
end
```

### 4. Add View Helpers

```erb
<!-- Show usage warnings -->
<%= plan_limit_banner :projects, billable: current_organization %>

<!-- Usage meters -->
<%= plan_usage_meter :projects, billable: current_organization %>

<!-- Pricing table -->
<%= plan_pricing_table highlight: true %>

<!-- Current plan info -->
<p>Current plan: <%= current_plan_name(current_organization) %></p>
<% if plan_allows?(current_organization, :api_access) %>
  <p>API access enabled!</p>
<% end %>
```

### 5. Generate Pricing Views (Optional)

```bash
rails generate pricing_plans:pricing
```

This creates a pricing controller, views, and CSS for your pricing page.

## 🎯 Key Features

### Plan Types

- **Free Plans**: `price 0`
- **Paid Plans**: `stripe_price "price_123"` (integrates with Pay gem)
- **Enterprise**: `price_string "Contact us"`

### Feature Flags

```ruby
plan :pro do
  allows :api_access, :premium_features, :priority_support
end

plan :free do
  disallows :api_access  # explicit denial
end
```

### Limit Types

**Persistent Caps** (max concurrent resources):
```ruby
limits :projects, to: 5.max, after_limit: :grace_then_block, grace: 7.days
```

**Per-Period Allowances** (discrete monthly/weekly limits):
```ruby
limits :custom_models, to: 3.max, per: :month, after_limit: :block_usage
```

### Grace Period Behaviors

- **`:grace_then_block`** (default) - Grace period, then block
- **`:block_usage`** - Block immediately  
- **`:just_warn`** - Never block, only warn

### Warning Thresholds

```ruby
limits :projects, to: 10.max, warn_at: [0.6, 0.8, 0.95]  # warn at 6, 8, 9.5 usage
```

## 🔗 Integrations

### Pay Gem Integration

Automatically resolves plans from active Stripe subscriptions:

```ruby
# In your billable model (User/Organization/Account):
class Organization < ApplicationRecord
  pay_customer stripe_attributes: :stripe_attributes
end
```

The gem reads subscription state and maps Stripe price IDs to your defined plans.

### Usage Credits Integration

Works seamlessly with the `usage_credits` gem:

```ruby
plan :pro do
  includes_credits 1_000, for: :api_calls  # Shows in pricing table
end
```

- Shows credit inclusions in pricing tables
- Prevents collisions (won't let you define both credits and per-period limits for same operation)
- You use `usage_credits` API directly for spending

## 🎨 Customization

### Custom Period Cycles

```ruby
config.period_cycle = :calendar_month  # or :calendar_week, :calendar_day
config.period_cycle = ->(billable) { [start_time, end_time] }  # custom logic
```

### Manual Plan Assignment

```ruby
# Override subscription-based plan resolution
PricingPlans::PlanResolver.assign_plan_manually!(organization, :enterprise)
```

### Result Objects

Controller guards return rich result objects:

```ruby
result = require_plan_limit! :projects, billable: current_org

result.ok?       # Within limit
result.warning?  # Approaching limit  
result.grace?    # In grace period
result.blocked?  # Over limit, blocked
result.message   # Human-friendly message
```

## 📊 Database Schema

The gem creates three tables:

- `pricing_plans_enforcement_states` - Grace period tracking
- `pricing_plans_usages` - Per-period usage counters  
- `pricing_plans_assignments` - Manual plan overrides

## 🧪 Testing

Use built-in test helpers:

```ruby
# RSpec matchers (coming soon)
expect(organization).to be_within_plan_limit(:projects)
expect(organization).to be_in_grace_for(:projects)
expect(organization).to be_blocked_for(:projects)
```

## 📚 Generators

- `rails g pricing_plans:install` - Install migrations and initializer
- `rails g pricing_plans:pricing` - Generate pricing views and controller
- `rails g pricing_plans:mailers` - Generate notification mailers

## 🔧 Configuration Options

```ruby
PricingPlans.configure do |config|
  config.billable_class = "Organization"    # Required
  config.default_plan = :free              # Required  
  config.highlighted_plan = :pro           # Optional
  config.period_cycle = :billing_cycle     # Default period for limits
end
```

## ⚡ Performance

- **Real-time counting**: No counter caches needed
- **Row-level locking**: Prevents race conditions
- **Efficient queries**: Optimized for concurrent usage
- **Grace state caching**: Avoids redundant database hits

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/pricing_plans.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
