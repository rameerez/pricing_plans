# frozen_string_literal: true

PricingPlans.configure do |config|
  # Required configuration
  # Set the billable class used in your app (e.g., "User", "Organization")
  config.billable_class = "Organization"
  config.default_plan = :free
  config.highlighted_plan = :pro

  # Period cycle for per-period limits
  # :billing_cycle, :calendar_month, :calendar_week, :calendar_day
  config.period_cycle = :billing_cycle

  # Example plans
  plan :free do
    name "Free"
    description "Perfect for getting started"
    price 0
    bullets "Basic features", "Community support"

    disallows :api_access, :premium_features
    limits :projects, to: 1.max, after_limit: :grace_then_block, grace: 10.days
    limits :team_members, to: 3.max
  end

  plan :pro do
    name "Pro"
    description "For growing teams and businesses"
    bullets "Advanced features", "Priority support", "API access"

    allows :api_access, :premium_features
    limits :projects, to: 25.max, after_limit: :grace_then_block, grace: 7.days
    unlimited :team_members
  end
end
