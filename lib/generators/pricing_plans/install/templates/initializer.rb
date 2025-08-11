# frozen_string_literal: true

# Enable pricing_plans DSL sugar like `1.max` within this initializer
using PricingPlans::IntegerRefinements

PricingPlans.configure do |config|
  # Example plans
  plan :free do
    price 0

    description   "Perfect for getting started"
    bullets       "Basic features", "Community support"

    limits :projects, to: 3.max, after_limit: :block_usage
    # Example scoped persistent cap (active-only rows)
    # limits :projects, to: 3.max, count_scope: { status: "active" }
    default!
  end

  plan :pro do
    description   "For growing teams and businesses"
    bullets       "Advanced features", "Priority support", "API access"

    allows :api_access, :premium_features
    limits :projects, to: 25.max, after_limit: :grace_then_block, grace: 7.days

    highlighted!
  end

  plan :enterprise do
    price_string  "Contact us"

    description   "Get in touch and we'll fit your needs."
    bullets       "Custom limits", "Dedicated SLAs", "Dedicated support"
    cta_text      "Contact sales"
    cta_url       "mailto:sales@example.com"

    unlimited :projects
    allows    :api_access, :premium_features
  end


  # Optional settings

  # Optional: global controller billable resolver (per-controller still wins)
  # Either a symbol helper name or a block evaluated in the controller
  # config.controller_billable :current_organization
  # or
  # config.controller_billable { current_account }

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

  # Controller ergonomics — global default redirect when a limit blocks
  # Accepts:
  #   - Symbol: a controller helper method, e.g. :pricing_path
  #   - String: a path or URL, e.g. "/pricing"
  #   - Proc: instance-exec'd in the controller with the Result: ->(result) { pricing_path }
  # Examples:
  # config.redirect_on_blocked_limit = :pricing_path
  # config.redirect_on_blocked_limit = "/pricing"
  # config.redirect_on_blocked_limit = ->(result) { pricing_path }


  #`config.message_builder` lets apps override human copy for `:over_limit`, `:grace`, `:feature_denied`, and overage report; used broadly across guards/UX.


  # Optional event callbacks -- enqueue jobs here to send notifications or emails when certain events happen
  # config.on_warning(:products)     { |org, threshold| PlanMailer.quota_warning(org, :products, threshold).deliver_later }
  # config.on_grace_start(:products) { |org, ends_at|   PlanMailer.grace_started(org, :products, ends_at).deliver_later  }
  # config.on_block(:products)       { |org|            PlanMailer.blocked(org, :products).deliver_later                 }
end
