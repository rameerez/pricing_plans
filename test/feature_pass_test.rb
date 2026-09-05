# frozen_string_literal: true

require "test_helper"

class FeaturePassTest < ActiveSupport::TestCase
  def setup
    super
    @owner = create_organization
  end

  def issue(**)
    @owner.issue_feature_pass!(:distribution, source: "sales", **)
  end

  def test_pass_has_limits_provenance_and_expiration
    deadline = 3.months.from_now
    pass = issue(limits: { storage_bytes: 1024 }, usage_limit: 2048, expires_at: deadline)
    access = @owner.feature_access(:distribution)

    assert_predicate access, :allowed?
    assert_equal :grant, access.source
    assert_equal pass, access.grant
    assert_equal 1024, access.limit(:storage_bytes)
    assert_equal 2048, access.remaining_allowance
    assert_in_delta deadline.to_f, access.expires_at.to_f, 0.001
  end

  def test_issue_never_overwrites_an_existing_promise
    original = @owner.grant_feature!(:distribution, source: "grandfather")
    assert_raises(PricingPlans::FeatureGrantConflict) { issue(expires_at: 1.day.from_now) }
    assert_nil original.reload.expires_at
    assert_equal "grandfather", original.source
  end

  def test_legacy_updates_preserve_limits_and_consumption_unless_explicitly_changed
    pass = issue(limits: { storage_bytes: 10 }, usage_limit: 20)
    @owner.with_feature_access!(:distribution, amount: 3) { :ok }
    @owner.grant_feature!(:distribution, note: "extended", expires_at: 1.day.from_now)

    assert_equal({ "storage_bytes" => 10 }, pass.reload.limits)
    assert_equal 20, pass.usage_limit
    assert_equal 3, pass.usage_count
  end

  def test_capacity_boundary_is_inclusive_and_does_not_consume_usage
    issue(limits: { storage_bytes: 10 })

    assert_equal :ok, @owner.with_feature_access!(:distribution, usage: -> { { storage_bytes: 10 } }) { :ok }
    error = assert_raises(PricingPlans::FeatureLimitExceeded) do
      @owner.with_feature_access!(:distribution, usage: -> { { storage_bytes: 11 } }) { flunk }
    end
    assert_equal :storage_bytes, error.limit_key
    assert_equal 10, error.allowed
    assert_equal 11, error.requested
  end

  def test_consumption_is_cumulative_and_cannot_exceed_the_allowance
    pass = issue(usage_limit: 10)
    @owner.with_feature_access!(:distribution, amount: 7) { :first }
    @owner.with_feature_access!(:distribution, amount: 3) { :last }

    assert_equal 10, pass.reload.usage_count
    assert_equal 0, @owner.feature_access(:distribution).remaining_allowance
    assert_raises(PricingPlans::FeatureLimitExceeded) do
      @owner.with_feature_access!(:distribution, amount: 1) { flunk }
    end
    # Publishing/finalizing a previously reserved upload costs zero additional units.
    assert_equal :published, @owner.with_feature_access!(:distribution) { :published }
  end

  def test_failure_rolls_back_both_consumption_and_business_write
    pass = issue(usage_limit: 10)
    assert_raises(RuntimeError) do
      @owner.with_feature_access!(:distribution, amount: 4) do
        @owner.projects.create!(name: "rolled back")
        raise "failed"
      end
    end
    assert_equal 0, pass.reload.usage_count
    assert_equal 0, @owner.projects.count
  end

  def test_nested_failure_does_not_leak_consumption_when_caller_rescues
    pass = issue(usage_limit: 10)
    Organization.transaction do
      assert_raises(RuntimeError) do
        @owner.with_feature_access!(:distribution, amount: 4) { raise "failed" }
      end
      @owner.update!(name: "outer commits")
    end

    assert_equal 0, pass.reload.usage_count
    assert_equal "outer commits", @owner.reload.name
  end

  def test_expiration_is_checked_at_write_time_even_after_a_successful_preview
    deadline = Time.utc(2026, 10, 1)
    travel_to_time(deadline - 1) do
      issue(expires_at: deadline)

      assert_predicate @owner.feature_access(:distribution), :allowed?
    end
    travel_to_time(deadline) do
      refute_predicate @owner.feature_access(:distribution), :allowed?
      assert_raises(PricingPlans::FeatureDenied) { @owner.with_feature_access!(:distribution) { flunk } }
    end
  end

  def test_paid_plan_wins_without_consuming_or_inheriting_a_pass_cap
    pass = @owner.issue_feature_pass!(:api_access, source: "sales", usage_limit: 1, limits: { calls: 1 })
    @owner.override_pricing_plan!(:pro, source: "admin")
    access = @owner.feature_access(:api_access)

    assert_equal :plan, access.source
    assert_equal :unlimited, access.limit(:calls)
    @owner.with_feature_access!(:api_access, amount: 50) { :ok }

    assert_equal 0, pass.reload.usage_count
  end

  def test_plan_access_carries_no_named_limits_and_leaves_plan_quotas_to_the_app
    @owner.override_pricing_plan!(:pro, source: "admin")
    access = @owner.feature_access(:api_access)

    assert_equal :plan, access.source
    assert_empty access.limits
    assert_equal :unlimited, access.limit(:calls)
    assert_equal :unlimited, access.remaining_allowance
    assert_equal :ok, @owner.with_feature_access!(:api_access, amount: 99, usage: -> { { calls: 6 } }) { :ok }
    error = assert_raises(PricingPlans::ConfigurationError) { PricingPlans::Registry.plan(:pro).allows :exports, limits: { calls: 5 } }
    assert_match(/feature passes/, error.message)
  end

  def test_invalid_pass_limits_are_rejected
    [nil, [], { storage: -1 }, { storage: "100" }, { storage: 1.5 }, { storage: false }, { "" => 1 }].each do |limits|
      assert_raises(ArgumentError, ActiveRecord::RecordInvalid) { issue(limits: limits) }
    end
    refute @owner.feature_granted?(:distribution)
  end

  def test_metered_write_locks_the_owner_once_and_never_opens_a_nested_savepoint
    pass = issue(usage_limit: 10)
    before = pass.reload.updated_at
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    begin
      @owner.with_feature_access!(:distribution, amount: 4) { :ok }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 1, statements.count { |sql| sql.match?(/SELECT .* FROM "organizations"/) },
                 "the owner row should be read exactly once, under the lock"
    assert_empty statements.grep(/SAVEPOINT/), "record_usage! must not re-enter the owner lock"
    assert_equal 1, statements.count { |sql| sql.start_with?("UPDATE") }
    assert_equal 4, pass.reload.usage_count
    assert_operator pass.updated_at, :>=, before
  end

  def test_consumption_is_only_exposed_through_the_owner_locked_write_api
    pass = issue(usage_limit: 10)
    stale = PricingPlans::FeatureGrant.find(pass.id)

    [pass, stale].each do |copy|
      refute_respond_to copy, :record_usage!
      assert_raises(NoMethodError) { copy.record_usage!(7) }
    end
    @owner.with_feature_access!(:distribution, amount: 7) { :ok }
    assert_raises(PricingPlans::FeatureLimitExceeded) do
      @owner.with_feature_access!(:distribution, amount: 7) { flunk }
    end
    assert_equal 7, pass.reload.usage_count
  end

  def test_invalid_usage_is_never_coerced_to_zero
    issue(usage_limit: 10)

    [-1, 1.2, "2", nil, Float::INFINITY, true].each do |amount|
      assert_raises(ArgumentError) { @owner.with_feature_access!(:distribution, amount: amount) { flunk } }
    end
    assert_raises(ArgumentError) do
      @owner.with_feature_access!(:distribution, usage: -> { { storage: -1 } }) { flunk }
    end
  end

  def test_missing_block_and_unsaved_owner_are_rejected
    assert_raises(ArgumentError) { @owner.with_feature_access!(:distribution) }
    assert_raises(ArgumentError) { Organization.new.with_feature_access!(:distribution) { flunk } }
  end

  def test_revocation_and_renewal_keep_history_and_reset_only_new_pass_usage
    original = issue(usage_limit: 10)
    @owner.with_feature_access!(:distribution, amount: 3) { :ok }
    @owner.revoke_feature!(:distribution)

    refute_predicate @owner.feature_access(:distribution), :allowed?
    replacement = issue(usage_limit: 10)

    assert_equal 3, original.reload.usage_count
    assert_equal 0, replacement.usage_count
    assert_equal 2, @owner.feature_grants.count
  end

  def test_dirty_owner_is_not_reloaded
    issue(usage_limit: 10)
    @owner.name = "unsaved"
    @owner.with_feature_access!(:distribution, amount: 1) { :ok }

    assert_equal "unsaved", @owner.name
    assert_predicate @owner, :changed?
  end

  def test_other_owners_cannot_spend_the_pass
    issue(usage_limit: 10)
    other = create_organization
    assert_raises(PricingPlans::FeatureDenied) { other.with_feature_access!(:distribution, amount: 1) { flunk } }
  end

  def test_revision_preserves_consumption_and_cannot_change_owner_or_feature
    pass = issue(usage_limit: 10)
    @owner.with_feature_access!(:distribution, amount: 4) { :ok }
    pass.revise!(usage_limit: 20, expires_at: 1.day.from_now)

    assert_equal 4, pass.reload.usage_count
    assert_equal 16, @owner.feature_access(:distribution).remaining_allowance
    assert_raises(ArgumentError) { pass.revise!(usage_count: 0) }
    assert_raises(ArgumentError) { pass.revise!(feature_key: "exports") }
    assert_raises(ArgumentError) { pass.revise!(plan_owner_id: create_organization.id) }
    pass.revoke!
    assert_raises(PricingPlans::FeatureGrantConflict) { pass.revise!(expires_at: 1.year.from_now) }
  end

  def test_zero_allowance_allows_zero_cost_operations_only
    issue(usage_limit: 0)

    assert_predicate @owner.feature_access(:distribution), :available?
    refute @owner.feature_access(:distribution).available?(amount: 1)
    assert_equal :published, @owner.with_feature_access!(:distribution) { :published }
  end

  def test_unlimited_capacity_and_allowance_survive_json_round_trip
    pass = issue(limits: { storage: :unlimited })

    assert_equal({ "storage" => "unlimited" }, pass.reload.limits)
    assert_equal :unlimited, @owner.feature_access(:distribution).limit(:storage)
    @owner.with_feature_access!(:distribution, amount: 10, usage: -> { { storage: 12345 } }) { :ok }

    assert_equal 10, pass.reload.usage_count
  end

  def test_invalid_allowances_and_unknown_options_are_rejected
    [-1, "10", false, 1.1, 2**63].each do |usage_limit|
      assert_raises(ArgumentError) { issue(usage_limit: usage_limit) }
    end
    assert_raises(ArgumentError) { issue(uses: 2) }
    assert_raises(ArgumentError) { issue(limits: { storage: 1, "storage" => 2 }) }
    assert_equal 0, @owner.feature_grants.count
  end

  def test_old_schema_supports_boolean_grants_but_rejects_new_pass_options
    grant = @owner.grant_feature!(:distribution)
    grant.stub(:has_attribute?, false) do
      assert_empty grant.pass_limits
      assert_nil grant.pass_usage_limit
      assert_equal 0, grant.pass_usage_count
    end
    PricingPlans::FeatureGrant.stub(:column_names, %w[id feature_key expires_at]) do
      error = assert_raises(PricingPlans::ConfigurationError) { issue(limits: { calls: 2 }) }
      assert_includes error.message, "pricing_plans:passes"
    end
  end

  def test_expired_pass_can_be_reissued_without_losing_history
    expired = issue(expires_at: 1.day.ago)
    replacement = issue(usage_limit: 10)

    refute_equal expired.id, replacement.id
    assert_equal 2, @owner.feature_grants.count
  end

  def test_usage_is_read_after_access_has_been_resolved_under_the_lock
    issue(limits: { storage: 1 })
    calls = 0
    @owner.with_feature_access!(:distribution, usage: lambda {
      calls += 1
      { storage: 1 }
    }) do |access|
      assert_predicate access, :allowed?
      assert_equal 1, calls
    end
    assert_raises(ArgumentError) { @owner.with_feature_access!(:distribution, usage: {}) { flunk } }
  end

  def test_reducing_allowance_below_consumption_blocks_new_work
    pass = issue(usage_limit: 10)
    @owner.with_feature_access!(:distribution, amount: 8) { :ok }
    pass.revise!(usage_limit: 5)

    assert_equal 0, @owner.feature_access(:distribution).remaining_allowance
    refute @owner.feature_access(:distribution).available?(amount: 1)
    assert_equal :published, @owner.with_feature_access!(:distribution) { :published }
    assert_equal 8, pass.reload.usage_count
  end

  def test_named_cap_requires_strict_nonnegative_usage
    issue(limits: { storage: 10 })

    [nil, [], { storage: "0" }, { storage: -1 }].each do |usage|
      assert_raises(ArgumentError) { @owner.with_feature_access!(:distribution, usage: -> { usage }) { flunk } }
    end
  end
end
