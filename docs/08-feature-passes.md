# Feature passes: samples, evaluations, and customer promises

A feature pass grants one plan owner access to a feature independently of billing.
Use it for a sales evaluation, support compensation, a partner promise, or beta
access. A pass can be permanent, expire at a deadline, carry named capacity limits,
and/or have a cumulative usage allowance. These are existing FeatureGrant rows,
not another subscription system. Available in 0.7.0.

## Issue a sample without replacing a promise

```ruby
pass = organization.issue_feature_pass!(
  :distribution,
  source: "sales_evaluation",
  note: "Evaluate managed updates; follow up after the first release",
  expires_at: 3.months.from_now,
  limits: { storage_bytes: 1.gigabyte, max_artifact_bytes: 200.megabytes },
  usage_limit: 2.gigabytes
)
```

This permits access until the deadline, at most 1 GB stored concurrently, and at
most 2 GB cumulatively reserved through the write API below. A single artifact
may be at most 200 MB. The host must supply its live capacity measurements.

`issue_feature_pass!` raises `PricingPlans::FeatureGrantConflict` if there is
already an active grant for this owner and feature. It never silently shortens
a permanent grant or replaces a support promise. `source:` is required.

Omit `expires_at` for permanent access. Omit `usage_limit` for no cumulative cap.
An omitted named limit is unlimited for an entitled feature; a feature with no
entitlement is still denied. Use `0` to prohibit consumption or a capacity, and
`:unlimited` explicitly where appropriate. Counts must be nonnegative integers
within signed bigint range; strings, fractional amounts, negatives, and unknown
options are rejected by the public pass APIs.

The existing `grant_feature!` remains an upsert. It now accepts `limits:` and
`usage_limit:` too. When omitted during an upsert, those two settings and consumed
usage are preserved. Existing semantics for source, note and expiration remain
unchanged (omitting expiration on that legacy API makes the grant permanent).
Use the create-only API for an operator's "issue" button.

## Read access and show an offer

```ruby
organization.plan_allows?(:distribution) # same boolean API as before
access = organization.feature_access(:distribution)
access.allowed?          # entitlement exists; does not mean every operation fits
access.source            # :plan | :grandfather | :grant | nil
access.grant             # selected grant row, or nil
access.expires_at        # grant deadline, or nil
access.limit(:storage_bytes) # integer or :unlimited
access.usage_count       # cumulative grant consumption
access.remaining_uses    # integer or :unlimited
access.available?(amount: upload.bytesize,
                  usage: { storage_bytes: stored_bytes + upload.bytesize,
                           max_artifact_bytes: upload.bytesize })
```

`FeatureAccess` is a snapshot for UI and preflight. Do not cache it across requests
or use an old snapshot to authorize a write. `available?` returns false on denial;
`check!` raises `FeatureDenied` or its `FeatureLimitExceeded` subclass, which exposes
`feature_key`, `plan_owner`, `limit_key`, `allowed`, and `requested`.

Boolean access is intentionally separate from consumption. A fully used upload
allowance still permits zero-cost operations, such as finalizing or publishing
an already reserved artifact. A new upload fails when it would exceed the
allowance. At `expires_at` exactly, the grant is inactive, including for zero-cost
writes. There is no expiry worker: the next entitlement check sees the deadline.

## Enforce and reserve in the same transaction

```ruby
organization.with_feature_access!(
  :distribution,
  amount: upload.bytesize,
  usage: -> {
    {
      storage_bytes: organization.artifacts.sum(:byte_size) + upload.bytesize,
      max_artifact_bytes: upload.bytesize
    }
  }
) do |access|
  organization.artifacts.create!(byte_size: upload.bytesize, filename: upload.filename)
end
```

The gem locks a fresh copy of the owner row, resolves access again, reads the
usage callable, checks the named limits and cumulative allowance, reserves the
amount, then yields. It bypasses query caches so a preflight read cannot stay
stale after waiting for a competing writer. It does not reload the caller's
unsaved attributes. The block's return value is returned.

All competing writes must use this API. Capacity values must be measured inside
the callable, on the owner's database connection. `amount:` and each value in
`usage:` are separate: the former is cumulative consumption, the latter is the
prospective capacity after this operation (or its size for a per-operation cap).
Only the dimensions the host supplies are checked; the gem cannot discover your
storage system or infer which operation uses a named limit. Declaring `limits:`
alone does not install callbacks on arbitrary models. Include each applicable
capacity dimension at its write boundary. Existing association limits continue
to use their own documented model integration.

The grant update and same-database business write roll back together on an
exception. A savepoint isolates failure even if an outer transaction rescues it.
A block that returns false still commits; use bang writes and raise on failure.
For controller actions that rescue internally, raise `ActiveRecord::Rollback`
inside the block when the rendered response is unsuccessful. External storage
and HTTP requests are not database transactions: reserve before handing out an
upload URL, and define abandoned-upload policy explicitly. Keep lock duration
short; stream file bytes outside it.

This API does not deduplicate arbitrary operations. Reuse an existing operation
record/idempotency key before reserving again. Uniqueness violations that escape
the block roll back consumption. Deleting artifacts does not refund cumulative
usage. Use live stored capacity when deletions should free room. The allowance
belongs to this grant lifecycle, with no periodic reset, transferable balance,
refund API, or purchase ledger; use `usage_credits` for a credit economy.

Row-level concurrency guarantees require a database such as PostgreSQL or MySQL.
SQLite does not provide equivalent row locks. Owners and grants must use the
same database/connection for atomicity. Direct SQL, `update_columns`, and writes
that bypass this API are outside the contract.

## Paid access wins

```ruby
plan :starter do
  allows :distribution, limits: {
    storage_bytes: 10.gigabytes,
    max_artifact_bytes: 1.gigabyte
  }
end
```

Precedence remains plan, then qualifying grandfather, then active grant. A paid
plan's access uses its own feature limits and does not spend or inherit a pass's
allowance. Limits do not stack and are not merged between sources. If the owner
later downgrades, an unexpired, unrevoked pass resumes with its previous consumed
usage. Buying a plan does not delete the pass. A plan that merely has a higher
price does not win unless it actually allows the feature.

Features already allowed without limits remain unrestricted. Grandfathered
access uses the resolved plan's feature-limit settings, where present; otherwise
it remains unrestricted. `Plan#feature_limits(feature)` exposes a defensive copy
of the named settings. These feature capacities are distinct from the existing
association/per-period `plan.limits` catalog.

## Revise or revoke explicitly

```ruby
pass.revise!(expires_at: 6.months.from_now, usage_limit: 4.gigabytes,
             note: "Customer requested time for the next release")
organization.revoke_feature!(:distribution, note: "Evaluation ended early")
organization.feature_grants # retained active, expired, and revoked lifecycles
```

`revise!` accepts only `expires_at`, `limits`, `usage_limit`, and `note`, preserves
consumption, and refuses expired/revoked rows. Lowering the allowance below used
usage blocks further consumption; it does not rewrite history. Passing nil to
`usage_limit` removes that cap. Passing `{}` to `limits` clears named caps.

Revocation is serialized with consumption. Revoking a grant cannot remove plan
or grandfather access. Issue a new pass after expiry/revocation for a new
allowance and history row. The table retains lifecycle history, not an immutable
log of every edit: revisions and legacy upserts update their row. Apps should
record the operator and reason, and append change notes or use their audit system.

## Installation and backwards compatibility

| Starting point | Command |
| --- | --- |
| New app | `rails generate pricing_plans:install` |
| App without feature grants (before 0.6.0) | `rails generate pricing_plans:grants` |
| App with the 0.6.x grants table | `rails generate pricing_plans:passes` |

Then run `rails db:migrate`. Run only the applicable generator, not all three.
The additive upgrade adds JSON `limits` (default `{}`), nullable bigint
`usage_limit`, bigint `usage_count` (default `0`), and a nonnegative usage check.
It does not alter owners, existing expirations, revocations, or billing rows.
Existing grants remain unbounded unless the app deliberately supplies a policy.

Old-schema boolean grants continue to work after upgrading gem code. New
capacity/consumption writes raise an actionable migration error before doing work
if the pass columns are missing. Deploy the schema before enabling pass UI and
metered write paths. No destructive backfill or scheduled expiry job is needed.

## A complete SaaS offering

The gem owns entitlement resolution, capacity comparison, deadlines, consumption,
locking, and lifecycle APIs. The app owns authenticated operator controls,
allowed feature/metric choices, units, emails, customer wording, pricing links,
and storage measurements. Never present an editable metric the app does not
actually enforce. An organization-owned SaaS should grant to the organization,
not a member's User record; a user-owned SaaS can include PlanOwner on User.

For distribution, a useful default is to block new uploads/publishing at expiry
while continuing to serve existing feeds and downloads. Enforce this by putting
gates on write endpoints only. Do not delete customer data as an expiry side
effect. Explain the deadline and paid continuation option before the evaluation.
A whole-plan Stripe trial or expiring plan override is a separate product:
feature passes do not create trials, change subscriptions, or expire assignments.
