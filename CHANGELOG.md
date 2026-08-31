## [0.6.0] - 2026-08-31

**Repricing without app migrations: grandfathering and per-owner feature grants.**

- Add the `grandfather` plan DSL: `grandfather :feature, subscribed_before: <time>` declares that owners whose qualifying pricing relationship predates the cutoff keep a feature the plan no longer `allows`. Pure configuration — no columns, no backfills, no rake tasks; the initializer stays the git-versioned record of every pricing change
- Grandfather eligibility uses the older of the current assignment and same-plan subscription `created_at`. It models a continuous pricing relationship (Pay keeps the same subscription row across price swaps, and updating an assignment keeps that row's age), not unavailable plan-change history; lapse/re-subscribe or clear/reassign resets the corresponding timestamp, while exact materialized cohorts belong in feature grants
- Add `PricingPlans::FeatureGrant` and the per-owner grants API: `grant_feature!`, `revoke_feature!`, `feature_granted?`, `feature_grants` — individual, auditable exceptions (comps, beta access, sales promises, remediation) that attach to the owner and survive plan changes and cancellation until expiry or revocation; revocation stamps `revoked_at` and keeps the row as history
- `plan_allows?` (and the `plan_allows_x?` sugar) now honors all three entitlement sources — plan, grandfather, grant — so existing app gates pick everything up with zero changes; `feature_entitlement_source` answers which one applied (`:plan | :grandfather | :grant | nil`)
- Keep `past_due` Pay subscriptions entitled while the processor retries payment, and prefer a current subscription whose processor price exists in the plan registry when an owner has several
- Use Rails' canonical polymorphic owner identity throughout assignments, grants, and admin scopes (including STI), and serialize grant mutations on the owner row so idempotent writes remain race-safe
- Declaring `grandfather` for a feature the plan still `allows` raises a `ConfigurationError` (one of the two lines is a mistake); unparseable cutoffs raise too, Rails `TimeWithZone` values are accepted, and date-only cutoffs are read as midnight UTC
- The install generator now creates `pricing_plans_feature_grants`; existing apps add it with the new `rails generate pricing_plans:grants` (plan-level grandfathering needs no table at all — reads degrade silently without it, grant writes raise with instructions)
- Advance the deprecation horizon to 0.7.0 (the APIs deprecated in 0.5.0 live one more minor)
- Stop storing a grace window on limits that never honor one: `grace` now defaults only for `:grace_then_block`, and declaring it explicitly with `:block_usage`/`:just_warn` raises a `ConfigurationError`. Previously every limit silently carried `grace: 7.days`, so anything reading `limit[:grace]` (downgrade UX, dunning emails) could promise customers a grace window that enforcement would never grant
- `OverageReporter` items now carry `grace_window` (the configured window on the target plan, enforced-only by construction) alongside the runtime `grace_active`/`grace_ends_at`, so downgrade and dunning copy can say "after a N-day grace window" without re-deriving enforcement rules
- Add docs/07-repricing.md (the full grandfathering + grants guide), make plan_allows? entitlement-awareness explicit in the model-helpers doc, and bless two long-requested recipes in the docs: reacting to plan changes via Pay lifecycle hooks (#13) and running multiple plan-owner models side by side (#22)

## [0.5.0] - 2026-08-31

- Add intention-revealing pricing plan override APIs: `override_pricing_plan!`, `clear_pricing_plan_override!`, `pricing_plan_overridden?`, `pricing_plan_override`, and `pricing_plan_override_source`
- Require explicit `source:` provenance when creating overrides through the new API
- Remove the implicit `"manual"` source default from newly generated assignment tables; legacy APIs still supply it explicitly for compatibility
- Add matching explicit `PlanResolver` and `Assignment` entry points, plus symmetric `override_pricing_plan_for!` and `clear_pricing_plan_override_for!` helpers on `Limitable` models, for lower-level use cases
- Add override-oriented provenance readers to `PlanResolution` while preserving its assignment-oriented compatibility readers
- Deprecate the ambiguous `assign_pricing_plan!`, `remove_pricing_plan!`, `assign_plan_manually!`, `remove_manual_assignment!`, `assign_plan_to`, and `remove_assignment_for` APIs through a gem-specific Active Support deprecator
- Guard legacy assignments of the configured default plan with configurable `:allow`, `:warn`, or `:raise` behavior; upgraded applications default to `:warn`, while newly generated initializers choose the safer `:raise`
- Clarify that ordinary free/default accounts should remain unassigned and that intentional default-tier pinning remains supported through the explicit override API

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
