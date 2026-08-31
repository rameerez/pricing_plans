## Unreleased

- Clarify that assigning the configured default plan still creates a manual override, and document that ordinary free/default accounts should remain unassigned

## [0.4.1] - 2026-08-24

- **Never 500 a pricing page when Stripe is unreachable**: `Plan#currency_symbol` was the one Stripe lookup without a rescue — a Stripe outage, rate limit, or missing API key (any test/CI environment) raised straight through the pricing page. It now degrades to `default_currency_symbol` like every other presentation method (#24)
- **`price` and `stripe_price` can be declared together**: the numeric price is the local source of truth for display and plan comparison (no network in the request path); the Stripe id stays the billing identity for checkout and subscription matching. Previously `validate_pricing!` forced a choice, which meant Stripe-priced plans had no local number — and when the live lookup failed, `comparable_price_cents` silently became 0 for every paid plan, so `upgrade_from?` and `next_upgrade_plan` stopped offering upgrades with no error and no log line (#25)
- Only `price_string` remains exclusive, since a label cannot be compared numerically
- Known edge: for a both-declared plan the yearly figure derives as 12x monthly; a discounted yearly Stripe price needs `price_components_resolver`

## [0.4.0] - 2026-03-19

- **Add plan provenance helpers**: `current_pricing_plan_resolution`, `current_pricing_plan_source`, and `PlanResolver.resolution_for(plan_owner)` now expose whether the effective plan comes from a manual assignment, a Pay subscription, or the default plan
- **Preserve underlying billing context**: resolution objects include the current subscription when present, even when a manual assignment overrides it for entitlements
- **Clarify effective plan vs billing state**: docs now explicitly distinguish the effective pricing plan from Pay/Stripe subscription status

## [0.3.2] - 2026-02-25

- **Fix stale grace warnings after plan upgrades**: Grace/blocked flags now auto-clear when usage drops below limit (self-healing state)
- **Fix grace triggering at exact limit**: `grace_then_block` now uses `>` (over limit) not `>=` (at limit)
- **Add lazy grace creation**: Grace starts on-demand when checking status, even if callbacks were bypassed
- **Add `ExceededStateUtils` module**: DRY extraction for shared exceeded/blocked logic

## [0.3.1] - 2026-02-16

- **Add `has_plan_assignment?` helper**: Check if a plan owner has a manual assignment without full plan resolution
- **Add `plan_assignment` helper**: Retrieve the assignment record directly for inspection

## [0.3.0] - 2026-02-15

- **Manual assignments now override subscriptions**: Admin overrides take precedence over Pay/Stripe plans (was incorrectly reversed) -- current plan resolution order: manual assignment → Pay subscription → default plan
- **Fix N+1 queries when checking status**: Request-scoped caching eliminates N+1 queries in `status()` calls (~85% query reduction)
- **Add automatic callbacks**: `on_limit_warning`, `on_limit_exceeded`, `on_grace_start`, `on_block` now fire automatically when limits change
- **Add useful admin scopes**: `within_all_limits`, `exceeding_any_limit`, `in_grace_period`, `blocked` for dashboard queries
- **EnforcementState uniqueness**: Fixed overly strict validation that blocked multi-limit scenarios

## [0.2.1] - 2026-01-15

- Added a `metadata` alias to plans, and documented its usage

## [0.2.0] - 2025-12-26

- Fix a bug in the pay gem integration that would always return the default pricing plan regardless of the actual Pay subscription
- Add hidden plans, enabling grandfathering, no-free-users use cases, etc.
- Prevent unlimited limits for limits that were undefined

## [0.1.1] - 2025-12-25

- Add support for Rails 8+
- Fix a bug where `throw :abort` was causing `UncaughtThrowError` exceptions in controller guards, and instead return `false` from `before_action` callbacks to halt the filter chain, rather than using the uncaught throw

## [0.1.0] - 2025-08-19

Initial release
