# frozen_string_literal: true

require "test_helper"

# Declarative grandfathering (`grandfather` in the plan DSL) and per-owner
# feature grants (FeatureGrant): the two ways an owner is entitled to a
# feature their plan does not carry. Both surface through the one predicate
# every app already calls, plan_allows?.
class FeatureGrandfatheringTest < ActiveSupport::TestCase
  CUTOFF = Time.utc(2026, 9, 1)

  def setup
    PricingPlans.reset_configuration!

    PricingPlans.configure do |config|
      config.default_plan = :free

      config.plan :free do
        name "Free"
        price 0
        limits :projects, to: 1
      end

      config.plan :legacy do
        name "Legacy"
        stripe_price "price_legacy_123"
        # :exports was removed from this plan; owners from before the cutoff
        # keep it.
        grandfather :exports, subscribed_before: CUTOFF
        limits :projects, to: 10
      end

      config.plan :premium do
        name "Premium"
        stripe_price "price_premium_123"
        allows :exports
        limits :projects, to: 100
      end
    end
  end

  def teardown
    PricingPlans.reset_configuration!
  end

  def old_timer(plan_price = "price_legacy_123")
    create_organization(name: "Old Timer").tap do |org|
      org.pay_subscription = { processor_plan: plan_price, active: true }
      org.pay_subscription_created_at = CUTOFF - 3.months
    end
  end

  def newcomer(plan_price = "price_legacy_123")
    create_organization(name: "Newcomer").tap do |org|
      org.pay_subscription = { processor_plan: plan_price, active: true }
      org.pay_subscription_created_at = CUTOFF + 3.days
    end
  end

  # --- Declarative grandfathering ------------------------------------------

  def test_a_subscriber_from_before_the_cutoff_keeps_the_feature
    assert old_timer.plan_allows?(:exports)
    assert_equal :grandfather, old_timer.feature_entitlement_source(:exports)
  end

  def test_a_subscriber_from_after_the_cutoff_does_not_get_the_feature
    refute newcomer.plan_allows?(:exports)
    assert_nil newcomer.feature_entitlement_source(:exports)
  end

  def test_the_plan_allows_sugar_honors_grandfathering
    assert old_timer.plan_allows_exports?
    refute newcomer.plan_allows_exports?
  end

  def test_an_owner_on_the_default_plan_has_no_tenure_and_no_grandfather
    drifter = create_organization(name: "No Sub")
    refute drifter.plan_allows?(:exports)
    assert_nil drifter.plan_tenure_started_at
  end

  def test_a_plan_that_allows_the_feature_reports_plan_as_the_source
    subscriber = old_timer("price_premium_123")
    assert subscriber.plan_allows?(:exports)
    assert_equal :plan, subscriber.feature_entitlement_source(:exports)
  end

  def test_grandfathering_via_manual_assignment_uses_the_assignment_age
    veteran = create_organization(name: "Assigned Veteran")
    veteran.override_pricing_plan!(:legacy, source: "admin")
    veteran.pricing_plan_override.update_column(:created_at, CUTOFF - 1.year)
    assert veteran.plan_allows?(:exports)

    latecomer = create_organization(name: "Assigned Latecomer")
    latecomer.override_pricing_plan!(:legacy, source: "admin")
    latecomer.pricing_plan_override.update_column(:created_at, CUTOFF + 1.day)
    refute latecomer.plan_allows?(:exports)
  end

  def test_a_late_assignment_cannot_strip_a_grandfathered_subscriber
    # Support adds a manual assignment today for an owner whose subscription
    # predates the cutoff: tenure is the OLDER of the two, so the
    # entitlement survives.
    org = old_timer
    org.override_pricing_plan!(:legacy, source: "support")
    org.pricing_plan_override.update_column(:created_at, CUTOFF + 1.week)
    assert org.plan_allows?(:exports),
      "tenure is the older of assignment and subscription; the post-cutoff assignment must not strip it"
  end

  def test_grandfather_cutoff_accepts_strings_and_dates_as_utc
    PricingPlans.reset_configuration!
    PricingPlans.configure do |config|
      config.default_plan = :free
      config.plan(:free) { name "Free"; price 0 }
      config.plan :stringly do
        name "Stringly"
        stripe_price "price_s_1"
        grandfather :exports, subscribed_before: "2026-09-01"
      end
    end

    plan = PricingPlans::Registry.plan(:stringly)
    assert_equal Time.utc(2026, 9, 1), plan.grandfather_cutoff_for(:exports)
    assert_equal [:exports], plan.grandfathered_features
  end

  def test_grandfathering_a_feature_the_plan_still_allows_is_a_configuration_error
    error = assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.reset_configuration!
      PricingPlans.configure do |config|
        config.default_plan = :free
        config.plan(:free) { name "Free"; price 0 }
        config.plan :confused do
          name "Confused"
          stripe_price "price_c_1"
          allows :exports
          grandfather :exports, subscribed_before: CUTOFF
        end
      end
    end
    assert_match(/grandfathers \[:exports\] but also allows/, error.message)
  end

  def test_an_unparseable_cutoff_is_a_configuration_error
    assert_raises(PricingPlans::ConfigurationError) do
      PricingPlans.reset_configuration!
      PricingPlans.configure do |config|
        config.default_plan = :free
        config.plan(:free) { name "Free"; price 0 }
        config.plan :broken do
          name "Broken"
          stripe_price "price_b_1"
          grandfather :exports, subscribed_before: "not a time"
        end
      end
    end
  end

  # --- Per-owner grants -----------------------------------------------------

  def test_a_grant_entitles_an_owner_regardless_of_plan
    drifter = create_organization(name: "Comped")
    refute drifter.plan_allows?(:exports)

    grant = drifter.grant_feature!(:exports, source: "founder_comp", note: "conference friend")

    assert drifter.plan_allows?(:exports)
    assert drifter.plan_allows_exports?
    assert_equal :grant, drifter.feature_entitlement_source(:exports)
    assert drifter.feature_granted?(:exports)
    assert_equal "founder_comp", grant.source
  end

  def test_granting_twice_updates_the_active_grant_instead_of_stacking
    org = create_organization(name: "Idempotent")
    org.grant_feature!(:exports)
    org.grant_feature!(:exports, note: "extended", expires_at: 1.year.from_now)

    assert_equal 1, org.feature_grants.count
    assert_equal "extended", org.feature_grants.sole.note
  end

  def test_an_expired_grant_no_longer_entitles
    org = create_organization(name: "Trial Over")
    org.grant_feature!(:exports, expires_at: 1.hour.ago)

    refute org.plan_allows?(:exports)
    refute org.feature_granted?(:exports)
  end

  def test_revoking_keeps_the_audit_row_but_ends_the_entitlement
    org = create_organization(name: "Revoked")
    org.grant_feature!(:exports, note: "eval")
    org.revoke_feature!(:exports, note: "eval ended")

    refute org.plan_allows?(:exports)
    assert_equal 1, org.feature_grants.count
    grant = org.feature_grants.sole
    assert grant.revoked_at.present?
    assert_match(/eval ended/, grant.note)
  end

  def test_a_fresh_grant_after_a_revocation_creates_a_new_row
    org = create_organization(name: "Round Two")
    org.grant_feature!(:exports)
    org.revoke_feature!(:exports)
    org.grant_feature!(:exports, note: "second chance")

    assert_equal 2, org.feature_grants.count
    assert org.plan_allows?(:exports)
  end

  def test_grants_survive_plan_changes_because_they_attach_to_the_owner
    org = newcomer
    org.grant_feature!(:exports, source: "grandfather_promise")
    assert org.plan_allows?(:exports)

    org.override_pricing_plan!(:free, source: "downgrade")
    assert org.plan_allows?(:exports), "a grant is a promise to the owner, not to the plan"
  end
end
