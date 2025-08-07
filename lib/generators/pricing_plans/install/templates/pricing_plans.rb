# frozen_string_literal: true

PricingPlans.configure do |config|
  # Required configuration
  config.billable_class = "Organization"  # or "User", "Account", etc.
  config.default_plan = :free
  config.highlighted_plan = :pro  # Optional: for UI highlighting
  
  # Period cycle for per-period limits
  # Options: :billing_cycle, :calendar_month, :calendar_week, :calendar_day
  # Or a custom callable: ->(billable) { [start_time, end_time] }
  config.period_cycle = :billing_cycle

  # Define your plans
  plan :free do
    name "Free"
    description "Perfect for getting started"
    price 0
    bullets "Basic features", "Community support"
    
    # Feature flags (booleans)
    disallows :api_access, :premium_features
    
    # Limits with grace periods
    limits :projects, to: 1.max, after_limit: :grace_then_block, grace: 10.days
    limits :team_members, to: 3.max
  end

  plan :pro do
    # Link to Stripe price for billing
    stripe_price "price_pro_monthly_29"
    
    name "Pro"
    description "For growing teams and businesses"
    bullets "Advanced features", "Priority support", "API access"
    
    # Features
    allows :api_access, :premium_features
    
    # Limits
    limits :projects, to: 25.max, after_limit: :grace_then_block, grace: 7.days
    unlimited :team_members
    
    # Optional: show credit inclusions (requires usage_credits gem)
    # includes_credits 1_000, for: :api_calls
    # includes_credits 500, for: :ai_generations
  end

  plan :enterprise do
    price_string "Contact us"
    name "Enterprise"
    description "Custom solutions for large organizations"
    bullets "Unlimited everything", "Dedicated support", "Custom integrations"
    
    allows :api_access, :premium_features, :enterprise_sso
    unlimited :projects, :team_members
    
    # Custom metadata
    meta support_tier: "dedicated", sla: "99.9%"
  end

  # Event handlers (optional)
  # Fired when users approach/exceed limits
  config.on_warning :projects do |billable, threshold|
    # Send warning email when approaching limit
    # PlanMailer.quota_warning(billable, :projects, threshold).deliver_later
  end

  config.on_grace_start :projects do |billable, grace_ends_at|
    # Send grace period notification  
    # PlanMailer.grace_started(billable, :projects, grace_ends_at).deliver_later
  end

  config.on_block :projects do |billable|
    # Send blocked notification
    # PlanMailer.blocked(billable, :projects).deliver_later
  end
end