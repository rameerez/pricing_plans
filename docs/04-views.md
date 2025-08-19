# Views: pricing pages, paywalls, usage indicators, conditional UI

Since `pricing_plans` is your single source of truth for pricing plans, you can query it at any time and get easy-to-display information to create views like pricing pages and paywalls very easily.

`pricing_plans` is UI-agnostic, meaning we don't ship any UI components with the gem, but we provide you with all the data you need to build UI components easily. You fully control the HTML/CSS, while `pricing_plans` gives you clear, composable data.

## Display all plans

`PricingPlans.plans` returns an array of `PricingPlans::Plan` objects containing all your plans defined in `pricing_plans.rb`

Each `PricingPlans::Plan` responds to:
  - `plan.free?`
  - `plan.highlighted?`
  - `plan.popular?` (alias of `highlighted?`)
  - `plan.name`
  - `plan.description`
  - `plan.bullets` → Array of strings
  - `plan.price_label` → The `price` or `price_string` you've defined for the plan. If `stripe_price` is set and the Stripe gem is available, it auto-fetches the live price from Stripe. You can override or disable this.
  - `plan.cta_text`
  - `plan.cta_url`

### Example: build a pricing page

Building a pricing table is as easy as iterating over all `Plans` and displaying their info:

```erb
<% PricingPlans.plans.each do |plan| %>
  <article class="card <%= 'is-current' if plan == current_user.current_pricing_plan %> <%= 'is-popular' if plan.highlighted? %>">
    <h3><%= plan.name %></h3>
    <p><%= plan.description %></p>
    <ul>
      <% plan.bullets.each do |b| %>
        <li><%= b %></li>
      <% end %>
    </ul>
    <div class="price"><%= plan.price_label %></div>
    <% if (url = plan.cta_url) %>
      <%= link_to plan.cta_text, url, class: 'btn' %>
    <% else %>
      <%= button_tag plan.cta_text, class: 'btn', disabled: true %>
    <% end %>
  </article>
<% end %>
```

> [!TIP]
> If you need more detail for the price (not just `price_label`, but also if it's monthly, yearly, etc.) check out the [Semantic Pricing API](/docs/05-semantic-pricing.md).


![pricing_plans Ruby on Rails gem - pricing table features](/docs/images/pricing_plans_ruby_rails_gem_pricing_table.jpg)

## Get the highlighted plan

You get helpers to access the highlighted plan:
  - `PricingPlans.highlighted_plan`
  - `PricingPlans.highlighted_plan_key`


## Get the next plan suggestion
  - `PricingPlans.suggest_next_plan_for(plan_owner, keys: [:projects, ...])`


## Conditional UI

![pricing_plans Ruby gem - conditional UI](/docs/images/product_creation_blocked.jpg)

We can leverage the [model methods and helpers](/docs/03-model-helpers.md) to build conditional UIs depending on pricing plan limits:

### Example: disable buttons when outside plan limits

You can gate object creation by enabling or disabling create buttons depending on limits usage:

```erb
<% if current_organization.within_plan_limits?(:projects) %>
  <!-- Show enabled "create new project" button -->
<% else %>
  <!-- Disabled button + hint -->
<% end %>
```

Tip: you could also use `plan_allows?(:api_access)` to build feature-gating UIs.

### Example: block an entire element if not in plan

```erb
<% if current_organization.plan_blocked_for?(:projects) %>
  <!-- Disabled UI; creation is blocked by the plan -->
<% end %>
```

## Alerts and usage

![pricing_plans Ruby on Rails gem - pricing plan upgrade prompt](/docs/images/pricing_plans_ruby_rails_gem_usage_alert_upgrade.jpg)

### Example: display an alert for a limit

```erb
<% if current_organization.attention_required_for_limit?(:projects) %>
  <%= render "shared/plan_limit_alert", plan_owner: current_organization, key: :projects %>
<% end %>
```

### Example: plan usage summary

```erb
<% s = current_organization.limit(:projects) %>
<div><%= s.key.to_s.humanize %>: <%= s.current %> / <%= s.allowed %> (<%= s.percent_used.round(1) %>%)</div>
<% if s.blocked %>
  <div class="notice notice--error">Creation blocked due to plan limits</div>
<% elsif s.grace_active %>
  <div class="notice notice--warning">Over limit — grace active until <%= s.grace_ends_at %></div>
<% end %>
```

Tip: you could also use `plan_limit_remaining(:projects)` and `plan_limit_percent_used(:projects)` to show current usage.

![pricing_plans Ruby on Rails gem - pricing plan usage meter](/docs/images/pricing_plans_ruby_rails_gem_usage_meter.jpg)

## Message customization

- You can override copy globally via `config.message_builder` in [`pricing_plans.rb`](/docs/01-define-pricing-plans.md), which is used across limit checks and features. Suggested signature: `(context:, **kwargs) -> string` with contexts `:over_limit`, `:grace`, `:feature_denied`, and `:overage_report`.