# Using `pricing_plans` with `pay` and/or `usage_credits`

`pricing_plans` is designed to work seamlessly with other complementary popular gems like [`pay`](https://github.com/pay-rails/pay) (to handle actual subscriptions and payments), and `usage_credits` (to handle credit-like spending and refills)

These gems are related but not overlapping. They're complementary. The boundaries are:
 - [`pay`](https://github.com/pay-rails/pay) handles billing
 - [`usage_credits`](https://github.com/rameerez/usage_credits/) handles user credits (metered usage through credits, ledger-like)

## `pay` gem

The integration with the `pay` gem should be seamless and is documented throughout the entire docs; however, to make it explicit:

There's nothing to do on your end to make `pricing_plans` work with `pay`!

As long as your `pricing_plans` config (`config/initializers/pricing_plans.rb`) contains a plan with the correct `stripe_price` ID, whenever a subscription to that Stripe price ID is found through the `pay` gem, `pricing_plans` will understand the user is subscribed to that plan automatically, and will start enforcing the corresponding limits.

The way `pricing_plans` works doesn't require any data migration, or callback setup, or any manual action. You don't need to call `assign_pricing_plan!` at all at any point, unless you're trying to something like overriding a plan, gifting users access to plans without any payment, or things like that.

As long as a matching `stripe_price` is found in the `pricing_plans.rb` initializer, the gem will know a user subscribed to that Stripe price ID is under the corresponding plan. Essentially, the gem just looks at the current `pay` subscriptions of your user. If a matching price ID is found in the `pricing_plans` configuration file, it enforces the corresponding limits.

> [!TIP]
> To make your `pricing_plans` gem config work across environments (production, development, etc.) instead of defining price IDs statically like this in the config:
>
> ```ruby
> stripe_price month: "price_123", year: "price_456"
> ```
>
> Try instead defining them dynamically using `Rails.env`, so the corresponding plan for each environment gets loaded automatically. A simple solution would be to define your plans in the credentials file, and then doing something like this in the `pricing_plans` config:
>
> ```ruby
> stripe_price month: Rails.application.credentials.dig(Rails.env.to_sym, :stripe_plans, :plan_name, :monthly), year: Rails.application.credentials.dig(Rails.env.to_sym, :stripe_plans, :plan_name, :yearly)
> ```
>
> You can come up with similar solutions, like adding that config to a plaintext `.yml` file if you don't want to store this info in the credentials file, but this is the overall idea.

## `usage_credits` gem

In the SaaS world, pricing plans and usage credits are related in so far credits are usually a part of a pricing plan. A plan would give you, say, 100 credits a month along other features, and users would find that information usually documented in the pricing table itself.

However, for the purposes of this gem, pricing plans and usage credits are two very distinct things.

If you want to add credits to your app, you should install and configure the [usage_credits](https://github.com/rameerez/usage_credits) gem separately. In the `usage_credits` configuration, you should specify how many credits your users get with each subscription.

### The difference between usage credits and per-period plan limits

> [!WARNING]
> Usage credits are not the same as per-period limits.

**Usage credits behave like a currency**. Per-period limits are not a currency, and shouldn't be purchaseable.

- **Usage credits** are like: "100 image-generation credits a month"
- **Per-period limits** are like: "Create up to 3 new projects a month"

Usage credits can be refilled (buy credit packs, your balance goes up), can be spent (your balance goes down). Per-period limits do not. If you intend to sell credit packs, or if the balance needs to go both up and down, you should implement usage credits, NOT per-period limits.

Some other examples of per-period limits: “1 domain change per week”, “2 exports/day”. Those are discrete allowances, not metered workloads. For classic metered workloads (API calls, image generations, tokenized compute), use credits instead.

Here's a few rules for a clean separation to help you decide when to use either gem:

`pricing_plans` handles:
  - Booleans (feature flags).
  - Persistent caps (max concurrent resources: products, seats, projects at a time).
  - Discrete per-period allowances (e.g., “3 exports / month”), with no overage purchasing.

`usage_credits` handles:
  - Metered consumption (API calls, generations, storage GB*hrs, etc.).
  - Included monthly credits via subscription plans.
  - Top-ups and pay-as-you-go.
  - Rollover/expire semantics and the entire ledger.

If a dimension is metered and you want to sell overage/top-ups, use credits only. Don’t also define a periodic limit for the same dimension in `pricing_plans`. We’ll actively lint and refuse dual definitions at boot.

### How to show `usage_credits` in `pricing_plans`

With all that being said, in SaaS users would typically find information about plan credits in the pricing plan table, and because of that, and since `pricing_plans` should be the single source of truth for pricing plans in your Rails app, you should include how many credits your plans give in `pricing_plans.rb`:

```ruby
PricingPlans.configure do |config|
  plan :pro do
    bullets "API access", "100 credits per month"
  end
end
```

`pricing_plans` ships some ergonomics to declare and render included credits, and guardrails to keep your configuration coherent when `usage_credits` is present.

#### Declare included credits in your plans (single currency)

Plans can advertise the total credits included. This is cosmetic for pricing UI; `usage_credits` remains the source of truth for fulfillment and spending:

```ruby
PricingPlans.configure do |config|
  config.plan :free do
    price 0
    includes_credits 100
  end

  config.plan :pro do
    price 29
    includes_credits 5_000
  end
end
```

When you’re composing your UI, you can read credits via `plan.credits_included`.

> [!IMPORTANT]
> You need to keep defining operations and subscription fulfillment in your `usage_credits` initializer, declaring it in pricing_plans is purely cosmetic and for ergonomics to render pricing tables.

#### Guardrails when `usage_credits` is installed

When the `usage_credits` gem is present, we lint your configuration at boot to prevent ambiguous setups:

Collisions between credits and per‑period plan limits are disallowed: you cannot define a per‑period limit for a key that is also a `usage_credits` operation (e.g., `limits :api_calls, to: 50, per: :month`). If a dimension is metered, use credits only.

This enforces a clean separation:

- Use `usage_credits` for metered workloads you may wish to top‑up or charge PAYG for.
- Use `pricing_plans` limits for discrete allowances and feature flags (things that don’t behave like a currency).

#### No runtime coupling; single source of truth

`pricing_plans` does not spend or refill credits — that’s owned by `usage_credits`.

- Keep using `@user.spend_credits_on(:operation, ...)`, subscription fulfillment, and credit packs in `usage_credits`.
- Treat `includes_credits` here as pricing UI copy only. The single source of truth for operations, costs, fulfillment cadence, rollover/expire, and balances lives in `usage_credits`.
