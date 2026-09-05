# frozen_string_literal: true

module PricingPlans
  # A per-owner feature entitlement that overrides plan resolution: comps,
  # beta access, sales exceptions, support remediation, or a grandfather
  # promise that must survive cancellation. Where the `grandfather` plan DSL
  # is cohort-level policy (config, no state), a grant is an individual,
  # auditable exception (a row, with a reason).
  #
  # Grants are never deleted by the API: revoking stamps `revoked_at` so the
  # answer to "why does this customer have this?" survives the revocation.
  class FeatureGrant < ActiveRecord::Base
    self.table_name = "pricing_plans_feature_grants"

    belongs_to :plan_owner, polymorphic: true

    validates :plan_owner, presence: true
    validates :feature_key, presence: true
    validates :source, presence: true
    validate :expires_at_must_be_parseable
    validate :pass_options_must_be_valid

    scope :for_feature, ->(feature_key) { where(feature_key: feature_key.to_s) }
    scope :active, lambda {
      where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current)
    }

    def active?
      revoked_at.nil? && (expires_at.nil? || expires_at > Time.current)
    end

    def revoke!(note: nil)
      self.class.with_owner_lock(plan_owner) do
        reload
        update!(revoked_at: Time.current, note: [self.note, note].compact.presence&.join(" | ")) unless revoked_at.present?
      end
      self
    end

    def pass_limits
      has_attribute?(:limits) ? FeatureAccess.normalize_limits(self[:limits] || {}) : {}
    end

    def pass_usage_limit = has_attribute?(:usage_limit) ? self[:usage_limit] : nil
    def pass_usage_count = has_attribute?(:usage_count) ? self[:usage_count] : 0

    # Internal to PlanOwner#with_feature_access!, which calls this on a row it
    # loaded fresh under the owner lock after FeatureAccess#check! passed. The
    # lock is what makes check-then-increment safe; this method neither
    # re-acquires it nor reloads. Keep this private: the database constraint
    # rejects negative counters, but cannot enforce the allowance or expiry.
    def record_usage!(amount)
      self.class.ensure_pass_columns!
      FeatureAccess.validate_amount!(amount)
      raise FeatureDenied, "This feature pass is no longer active." unless active?

      total = pass_usage_count + amount
      FeatureAccess.validate_amount!(total)
      if pass_usage_limit && total > pass_usage_limit
        raise FeatureLimitExceeded.new(feature_key: feature_key, plan_owner: plan_owner,
                                       limit_key: :usage, allowed: pass_usage_limit, requested: total)
      end

      increment!(:usage_count, amount, touch: true)
    end
    private :record_usage!

    # Revise a specific lifecycle without resetting consumption or resurrecting it.
    def revise!(**options)
      unknown = options.keys - [:expires_at, :note, :limits, :usage_limit]
      raise ArgumentError, "unknown revision options: #{unknown.join(', ')}" if unknown.any?
      self.class.ensure_pass_columns! if (options.keys & [:limits, :usage_limit]).any?
      self.class.with_owner_lock(plan_owner) do
        reload
        raise FeatureGrantConflict, "This pass is no longer active; issue a new pass." unless active?
        options[:limits] = FeatureAccess.normalize_limits(options[:limits]) if options.key?(:limits)
        FeatureAccess.validate_amount!(options[:usage_limit]) if options.key?(:usage_limit) && !options[:usage_limit].nil?
        update!(**options)
      end
      self
    end

    class << self
      # Idempotent: updates the active grant for (owner, feature) if one
      # exists, otherwise creates it. Revoked grants stay behind as history.
      def grant_to!(plan_owner, feature_key, source: "manual", note: nil, expires_at: nil, replace: true, **options)
        ensure_table!
        ensure_persisted_owner!(plan_owner)
        unknown = options.keys - [:limits, :usage_limit]
        raise ArgumentError, "unknown pass options: #{unknown.join(', ')}" if unknown.any?
        ensure_pass_columns! if options.any?
        options[:limits] = FeatureAccess.normalize_limits(options[:limits]) if options.key?(:limits)
        FeatureAccess.validate_amount!(options[:usage_limit]) if options.key?(:usage_limit) && !options[:usage_limit].nil?

        # Serialize grant writes through the owner row. A lookup followed by
        # create is otherwise race-prone, and a portable partial unique index
        # cannot express "unrevoked and unexpired" consistently on every
        # supported database.
        with_locked_owner(plan_owner) do
          grant = active.find_by(owner_conditions(plan_owner).merge(feature_key: feature_key.to_s))
          if grant
            raise FeatureGrantConflict, "An active grant already exists for #{feature_key}; revise it explicitly." unless replace
            grant.update!(source: source.to_s, note: note, expires_at: expires_at, **options)
            grant
          else
            create!(
              plan_owner: plan_owner,
              feature_key: feature_key.to_s,
              source: source.to_s,
              note: note,
              expires_at: expires_at,
              **options
            )
          end
        end
      end

      def revoke_for!(plan_owner, feature_key, note: nil)
        ensure_table!
        ensure_persisted_owner!(plan_owner)

        with_locked_owner(plan_owner) do
          active
            .where(owner_conditions(plan_owner).merge(feature_key: feature_key.to_s))
            .map { |grant| grant.revoke!(note: note) }
        end
      end

      def active_for?(plan_owner, feature_key)
        return false unless table_ready?

        active.where(owner_conditions(plan_owner).merge(feature_key: feature_key.to_s)).exists?
      end

      # The grants table ships with fresh installs; apps that installed an
      # earlier version add it with `rails generate pricing_plans:grants`.
      # Plan-level checks (`allows` and `grandfather`) work without it, so
      # its absence only disables per-owner grants — silently for reads,
      # loudly for writes.
      def table_ready?
        table_exists?
      rescue ActiveRecord::ActiveRecordError
        false
      end

      def ensure_pass_columns!
        return if %w[limits usage_limit usage_count].all? { |name| column_names.include?(name) }

        raise ConfigurationError, "Run `rails generate pricing_plans:passes && rails db:migrate` to add feature pass limits."
      end

      def with_owner_lock(plan_owner, &block)
        ensure_persisted_owner!(plan_owner)
        with_locked_owner(plan_owner, &block)
      end

      private

      def ensure_table!
        return if table_ready?

        raise ConfigurationError,
              "The #{table_name} table does not exist. Run " \
              "`rails generate pricing_plans:grants && rails db:migrate` to add it."
      end

      def owner_conditions(plan_owner)
        PlanOwnerIdentity.conditions_for(plan_owner)
      end

      def ensure_persisted_owner!(plan_owner)
        persisted_active_record = plan_owner.respond_to?(:persisted?) &&
                                  plan_owner.persisted? &&
                                  plan_owner.class.respond_to?(:base_class)
        return if persisted_active_record

        raise ArgumentError, "plan_owner must be a persisted Active Record"
      end

      def with_locked_owner(plan_owner)
        owner_class = plan_owner.class.base_class

        owner_class.uncached do
          owner_class.transaction(requires_new: true) do
            # Lock a fresh copy without changing the caller's unsaved attributes.
            # Bypass preflight query caches after waiting for another writer.
            owner_class.unscoped.lock.find(plan_owner.id)
            yield
          end
        end
      end
    end

    private

    def pass_options_must_be_valid
      pass_limits
      FeatureAccess.validate_amount!(pass_usage_count)
      FeatureAccess.validate_amount!(pass_usage_limit) unless pass_usage_limit.nil?
    rescue ArgumentError => error
      errors.add(:base, error.message)
    end

    def expires_at_must_be_parseable
      raw_value = expires_at_before_type_cast
      return if raw_value.nil? || (raw_value.is_a?(String) && raw_value.blank?)
      return if expires_at.respond_to?(:to_time)

      errors.add(:expires_at, "must be a valid time")
    end
  end
end
