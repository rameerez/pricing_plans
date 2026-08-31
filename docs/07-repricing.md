# Repricing: grandfathering and feature grants

Sooner or later you'll change your pricing: a feature that used to live on a cheap plan moves to a higher one. The customers who already pay you should keep what they signed up for — and that should not cost you new columns, backfill migrations, or bypass code in your gates.

`pricing_plans` handles both halves of this natively (since 0.6.0):

- **Grandfathering** — cohort-level policy, declared in your initializer. Zero database state.
- **Feature grants** — per-owner exceptions (comps, beta access, sales promises), stored and auditable.

Both flow through `plan_allows?` and the `plan_allows_<feature>?` sugar, so every gate you've already written picks them up with no changes.

## Grandfathering (one line, zero state)

Say `:distribution` used to be on your `:indie` plan and now starts at `:starter`. Remove it from `allows`, and declare the grandfather right next to it:

```ruby
plan :indie do
  allows      :api_access
  grandfather :distribution, subscribed_before: "2026-09-01"
end

plan :starter do
  allows :api_access, :distribution
end
```

That's the entire repricing migration. Owners whose qualifying pricing relationship predates the cutoff keep `:distribution`; everyone who arrives later sees your upgrade gate. Your initializer stays the single, git-versioned record of what changed and when — future-you can read the whole pricing policy in one file.

### The semantics, precisely

- **Eligibility time** is the older of the current manual assignment and a current subscription whose processor price maps to the same resolved plan. A subscription on another plan is ignored, so it cannot manufacture grandfather rights for a new override.
- Pay updates the same subscription row during an in-place price swap, preserving its original `created_at`; changing the plan key on an existing assignment also keeps that row's age. Grandfathering therefore measures a **continuous pricing relationship**, not the exact date that the current plan or price was selected. If your policy needs an exact historical plan-enrollment cohort, materialize that cohort with grants instead.
- Grandfathering rides that continuous relationship. Cancel and re-subscribe, or clear and later recreate an assignment, and the customer re-enters at current pricing. If you promised someone the feature *forever*, that's a grant (below).
- `active`, trialing, grace-period, and `past_due` subscriptions remain entitlement-bearing; canceled and unpaid subscriptions do not. This keeps access stable while a processor retries a failed payment.
- Cutoffs accept a `Time`, `ActiveSupport::TimeWithZone`, `Date`, or `String`. Date-only values are read as **midnight UTC**.
- Owners on the default (free) plan have no qualifying relationship timestamp and are never grandfathered.
- Declaring `grandfather` for a feature the plan still `allows` raises a `ConfigurationError` at boot — one of those two lines is a mistake.

> [!TIP]
> Pick a cutoff just **after** your deploy moment (e.g. tomorrow's date), so anyone who signs up while you're shipping the change lands on the generous side of the line.

## Feature grants (per-owner exceptions)

For individual exceptions, grant the feature to the owner directly:

```ruby
org.grant_feature!(:distribution, source: "founder_comp", note: "conference friend")
org.grant_feature!(:sso, source: "sales", expires_at: 30.days.from_now)

org.plan_allows?(:sso)          # => true
org.feature_granted?(:sso)      # => true (an active grant row exists)

org.revoke_feature!(:sso, note: "eval over")
org.feature_grants              # retained grant/revocation history
```

Use grants for:

- **Comps** — a friend, a case study, an influencer.
- **Beta access** — grant a feature to a handful of owners before it's on any plan.
- **Sales promises** — "you'll get X while you evaluate", with `expires_at`.
- **Support remediation** — "we broke your week, here's X until renewal".
- **A grandfather that must survive cancellation** — grants attach to the owner, not the plan, so they persist through plan changes and cancellation until expiry or revocation.

Grants are **never deleted** by the API: revoking stamps `revoked_at` and keeps the row, preserving each grant/revocation lifecycle. Updating an active grant changes that row; this is not an event-by-event audit log of every field edit.

Granting the same feature twice updates the active grant instead of stacking; revoking and granting again creates a fresh row (history preserved).

### The table

Fresh installs get the `pricing_plans_feature_grants` table from the install generator. If you installed pricing_plans before 0.6.0, add it with:

```bash
rails generate pricing_plans:grants && rails db:migrate
```

Declarative grandfathering needs **no table at all**. Without the table, grant *reads* silently report no grants, and grant *writes* raise with the command above.

## Which one applied?

When you're debugging or answering a support ticket, ask the owner directly:

```ruby
org.feature_entitlement_source(:distribution)
# => :plan         (the resolved plan allows it)
# => :grandfather  (qualifying pricing relationship predates the cutoff)
# => :grant        (an active per-owner grant)
# => nil           (not entitled)

org.pricing_relationship_started_at
# => qualifying same-plan subscription / assignment timestamp (or nil)
```

## A real-world example

[LicenseSeat](https://licenseseat.com) moved its software-distribution feature from its $9 plan to its $29 plan. The entire grandfather for every existing subscriber was the one `grandfather :distribution, subscribed_before:` line in the initializer — no schema changes, and the app's feature gates (plain `plan_allows?(:distribution)` calls) didn't change at all.
