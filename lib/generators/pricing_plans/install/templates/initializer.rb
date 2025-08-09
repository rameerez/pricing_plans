# frozen_string_literal: true

# Enable pricing_plans DSL sugar like `1.max` within this initializer
using PricingPlans::IntegerRefinements

PricingPlans.configure do |config|
  # Example plans
  plan :free do
    price 0
    description "Perfect for getting started"
    bullets "Basic features", "Community support"

    limits :projects, to: 1.max, after_limit: :block_usage
    limits :team_members, to: 3.max
    default!
  end

  plan :pro do
    description "For growing teams and businesses"
    bullets "Advanced features", "Priority support", "API access"

    allows :api_access, :premium_features
    limits :projects, to: 25.max, after_limit: :grace_then_block, grace: 7.days
    unlimited :team_members
    highlighted!
  end

  # Optional ergonomics
  # You can specify your billable class if you want controller inference to prefer it (e.g., "User", "Organization").
  # Otherwise it will try common conventions like current_organization, current_user, etc.
  # config.billable_class = "Organization"
  # Optional (can also be set via plan DSL sugar: `default!` / `highlighted!`)
  # config.default_plan = :free
  # config.highlighted_plan = :pro

  # Period cycle for per-period limits
  # :billing_cycle, :calendar_month, :calendar_week, :calendar_day
  # Global default period for per-period limits (can be overridden per limit via `per:`)
  # config.period_cycle = :billing_cycle

  # Optional defaults for pricing UI calls-to-action
  # config.default_cta_text = "Choose plan"
  # config.default_cta_url  = nil # e.g., checkout path or marketing URL
  # To auto-derive CTA URL for stripe_price plans when Pay is available, you can either:
  # - Use the view helper `pricing_plans_auto_cta_url` with a custom generator proc in your view/controller, or
  # - Set a global generator proc here. Example for Stripe Checkout:
  #
  # config.auto_cta_with_pay = ->(billable, plan, view) do
  #   billable.set_payment_processor :stripe unless billable.respond_to?(:payment_processor) && billable.payment_processor
  #   price_id = plan.stripe_price.is_a?(Hash) ? (plan.stripe_price[:id] || plan.stripe_price.values.first) : plan.stripe_price
  #   session = billable.payment_processor.checkout(
  #     mode: "subscription",
  #     line_items: [{ price: price_id }],
  #     success_url: view.root_url,
  #     cancel_url: view.root_url
  #   )
  #   session.url
  # end

end
