
# Views: pricing pages, paywalls, usage indicators, conditional UI

Since `pricing_plans` is your single source of truth for pricing plans, you can query it at any time and get easy-to-display information to create views like pricing pages and paywalls very easily.

## Get all plans



We provide a small, consolidated set of data helpers that make it dead simple to build your own pricing and usage UIs.

- Pricing data for tables/cards:
  - `PricingPlans.plans` → Array of `PricingPlans::Plan` objects
  - `plan.price_label` → "Free", "$29/mo", or "Contact". If `stripe_price` is set and the Stripe gem is available, it auto-fetches the live price from Stripe. You can override or disable this (see below).
  - `PricingPlans.suggest_next_plan_for(billable, keys: [:projects, ...])`
  - `plan.free?` and `current_organization.on_free_plan?` (syntactic sugar for quick checks)
  - `plan.popular?` (alias of `highlighted?`)
  - Global helpers: `PricingPlans.highlighted_plan`, `PricingPlans.highlighted_plan_key`, `PricingPlans.popular_plan`, `PricingPlans.popular_plan_key`

- Usage/status for settings dashboards:
  - `org.limit(:projects)` → one status item for a limit. Fields:
    - key, human_key, current, allowed, percent_used
    - grace_active, grace_ends_at, blocked, per
    - severity, severity_level (0..4), attention?
    - message (nil unless non-:ok), overage, remaining, unlimited, after_limit
    - next_creation_blocked?
    - warn_thresholds, next_warn_percent
    - period_start, period_end, period_seconds_remaining (per-period only)
    - Example:
      ```erb
      <% s = current_organization.limit(:projects) %>
      <div><%= s.key.to_s.humanize %>: <%= s.current %> / <%= s.allowed %> (<%= s.percent_used.round(1) %>%)</div>
      <% if s.blocked %>
        <div class="notice notice--error">Creation blocked due to plan limits</div>
      <% elsif s.grace_active %>
        <div class="notice notice--warning">Over limit — grace active until <%= s.grace_ends_at %></div>
      <% end %>
      ```
    - Note: prefer `org.limit(:key)` when you need a single item. It always returns a single `StatusItem`.
  - `org.limits(:projects, :custom_models)` → Array of status items (with no args, defaults to all limits on the current plan). Each item includes severity, severity_level, message, overage, remaining, next_creation_blocked?, warn info, and period window (for per-period limits).
    - Note: `org.limits` always returns an Array, even when you pass a single key (e.g., `org.limits(:projects)`). Use `org.limit(:projects)` if you need just one item.
    - The returned Array also exposes precomputed overall helpers:
      - `overall_severity`, `overall_severity_level`, `overall_attention?`
      - `overall_title`, `overall_message`
      - `overall_keys`, `overall_highest_keys`, `overall_highest_limits`
      - `overall_keys_sentence`, `overall_noun`, `overall_has_have`
      - `overall_cta_text`, `overall_cta_url`
  - `org.limits_summary(:projects, :custom_models)` → Alias of `org.limits`.
  - `org.limits_overview(:projects, :custom_models)` → Thin wrapper around `org.limits`’ overall helpers, convenient for JSON: `{ severity:, severity_level:, title:, message:, attention?:, keys:, highest_keys:, highest_limits:, keys_sentence:, noun:, has_have:, cta_text:, cta_url: }`.
  - `org.limits_severity(:projects, :custom_models)` → `:ok | :warning | :at_limit | :grace | :blocked`.
  - `org.limits_message(:projects, :custom_models)` → Combined human message string (or `nil`).

  - Pure-data, English-like helpers for views (no UI components):
    - Single-limit intents on the billable:
      - `org.limit_severity(:projects)` → `:ok | :warning | :at_limit | :grace | :blocked`
      - `org.limit_message(:projects)` → `String | nil`
      - `org.limit_overage(:projects)` → `Integer` (0 if within)
      - `org.attention_required_for_limit?(:projects)` → `true | false` (alias for any of warning/grace/blocked)
      - `org.approaching_limit?(:projects, at: 0.9)` → `true | false` (uses highest `warn_at` if `at` omitted)
      - `org.plan_cta` → `{ text:, url: }` from current plan or global defaults
    - Top-level equivalents if you prefer: `PricingPlans.severity_for(billable, :projects)`, `message_for`,
      `overage_for`, `attention_required?(billable, :projects)`, `approaching_limit?(billable, :projects, at: 0.9)`, `cta_for(billable)`

    - One-call alert view-model (pure data, no HTML):
      - `org.limit_alert(:products)` or `PricingPlans.alert_for(org, :products)` returns:
        `{ visible?: true/false, severity:, title:, message:, overage:, cta_text:, cta_url: }`
    - One-call banner overview across keys (pure data):
      - `org.limits_overview(:products, :licenses)` returns:
        `{ severity:, severity_level:, title:, message:, attention?:, keys:, highest_keys:, highest_limits:, keys_sentence:, noun:, has_have:, cta_text:, cta_url: }`

## Simple ERB examples

- Gate creation by ability to add one more (recommended for create buttons):

```erb
<% if current_organization.within_plan_limits?(:products) %>
  <!-- Show enabled "create new product" button -->
<% else %>
  <!-- Disabled button + hint -->
<% end %>
```

- Strict block check:

```erb
<% if current_organization.plan_blocked_for?(:products) %>
  <!-- Creation blocked by plan -->
<% end %>
```

- One-line alert decision + render:

```erb
<% if current_organization.attention_required_for_limit?(:products) %>
  <%= render "shared/plan_limit_alert", billable: current_organization, key: :products %>
<% end %>
```

## Titles, messages, and CTA defaults

- Severity order: `:blocked` > `:grace` > `:at_limit` > `:warning` > `:ok`.
- Titles (defaults):
  - `warning`: "Approaching Limit"
  - `at_limit`: "At Limit"
  - `grace`: "Limit Exceeded (Grace Active)"
  - `blocked`: "Cannot create more resources"
- Messages come from your `config.message_builder` when present; otherwise we provide sensible defaults, e.g.:
  - Blocked: "Cannot create more <key> on your current plan."
  - Grace: "Over the <key> limit, grace active until <date>."
  - At limit: "You are at <current>/<limit> <key>. The next will exceed your plan."
  - Warning: "You have used <current>/<limit> <key>."
- CTA: we resolve CTA as follows:
  - Plan-specific CTA if set (`plan.cta_url` / `cta_text`)
  - Global defaults (`config.default_cta_url` / `default_cta_text`)
  - Fallback: if `config.redirect_on_blocked_limit` is a String path/URL, we use it as CTA URL.

    Example (you craft the UI; we give you clean data):
    ```erb
    <% if current_organization.attention_required_for_limit?(:products) %>
      <% sev = current_organization.limit_severity(:products) %>
      <% msg = current_organization.limit_message(:products) %>
      <% cta = current_organization.plan_cta %>
      <!-- Render your own banner/button using sev/msg/cta -->
    <% end %>
    ```

    Recommended ERB usage patterns:

    - Gate create actions by ability to add one more (most ergonomic for buttons):
      ```erb
      <% if current_organization.within_plan_limits?(:products) %>
        <!-- Show enabled create button -->
      <% else %>
        <!-- Disabled button + hint -->
      <% end %>
      ```

    - Check whether creation is blocked (strict block semantics):
      ```erb
      <% if current_organization.plan_blocked_for?(:products) %>
        <!-- disabled UI; creation is blocked by the plan -->
      <% end %>
      ```

    - Show an attention banner (warning/grace/blocked):
      ```erb
      <% if current_organization.attention_required_for_limit?(:products) %>
        <% sev = current_organization.limit_severity(:products) %>
        <% msg = current_organization.limit_message(:products) %>
        <% cta = current_organization.plan_cta %>
        <!-- Your banner markup here, using sev/msg/cta -->
      <% end %>
      ```

- Feature toggles (billable-centric):
  - `current_user.plan_allows?(:api_access)`
  - `current_user.plan_limit_remaining(:projects)` and `current_user.plan_limit_percent_used(:projects)`

Message customization:

- You can override copy globally via `config.message_builder`, which is used across limit checks and features. Suggested signature: `(context:, **kwargs) -> string` with contexts `:over_limit`, `:grace`, `:feature_denied`, and `:overage_report`.

## Example: pricing table in ERB

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

Controller‑first Stripe Checkout wiring (recommended): define a conventional `subscribe` route and we’ll auto‑use it in `plan.cta_url` when present.

```ruby
# config/routes.rb
get "subscribe", to: "subscriptions#checkout", as: :subscribe

# app/controllers/subscriptions_controller.rb
class SubscriptionsController < ApplicationController
  def checkout
    billable = current_organization || current_user
    plan     = PricingPlans.registry.plan(params.require(:plan))
    interval = (params[:interval].presence || "month").to_sym
    price_id = interval == :year ? plan.yearly_price_id : plan.monthly_price_id

    billable.set_payment_processor(:stripe) unless billable.payment_processor
    session = billable.payment_processor.checkout(
      mode: "subscription",
      line_items: [{ price: price_id }],
      success_url: root_url,
      cancel_url:  root_url
    )
    redirect_to session.url, allow_other_host: true, status: :see_other
  end
end
```

Then link to it in your views:

```erb
<%= link_to plan.cta_text, subscribe_path(plan: plan.key, interval: :month), class: "btn" %>
```

Notes:
- If you omit the link and leave `plan.cta_url` unset, `plan.cta_url` will automatically return `/subscribe?plan=...&interval=month` when your app defines `subscribe_path`.
- Use `:interval` toggles in your UI to choose monthly/yearly; `plan.monthly_price_id` / `plan.yearly_price_id` are available if you need raw IDs.

## Example: settings usage summary (billable-centric)

```erb
<% org = current_organization %>
<% org.limits(:projects, :custom_models).each do |s| %>
  <div><%= s.key.to_s.humanize %>: <%= s.current %> / <%= s.allowed %> (<%= s.percent_used.round(1) %>%)
    <% if s.severity != :ok %>
      — <%= s.severity %><%= ": #{s.message}" if s.message.present? %>
      <%# gate create buttons %>
      <% if s.next_creation_blocked? %>
        <span class="badge">Blocked</span>
      <% end %>
    <% end %>
  </div>
<% end %>

<% ov = org.limits_overview(:projects, :custom_models) %>
<% if ov[:attention?] %>
  <div class="notice notice--<%= ov[:severity] %>"><%= ov[:message] %></div>
<% end %>
```

That’s it: you fully control the HTML/CSS, while `pricing_plans` gives you clear, composable data.
