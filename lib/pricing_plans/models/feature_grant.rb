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

    scope :for_feature, ->(feature_key) { where(feature_key: feature_key.to_s) }
    scope :active, lambda {
      where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current)
    }

    def active?
      revoked_at.nil? && (expires_at.nil? || expires_at > Time.current)
    end

    def revoke!(note: nil)
      return self if revoked_at.present?

      update!(revoked_at: Time.current, note: [self.note, note].compact.presence&.join(" | "))
      self
    end

    class << self
      # Idempotent: updates the active grant for (owner, feature) if one
      # exists, otherwise creates it. Revoked grants stay behind as history.
      def grant_to!(plan_owner, feature_key, source: "manual", note: nil, expires_at: nil)
        ensure_table!
        ensure_persisted_owner!(plan_owner)

        # Serialize grant writes through the owner row. A lookup followed by
        # create is otherwise race-prone, and a portable partial unique index
        # cannot express "unrevoked and unexpired" consistently on every
        # supported database.
        with_locked_owner(plan_owner) do
          grant = active.find_by(owner_conditions(plan_owner).merge(feature_key: feature_key.to_s))
          if grant
            grant.update!(source: source.to_s, note: note, expires_at: expires_at)
            grant
          else
            create!(
              plan_owner: plan_owner,
              feature_key: feature_key.to_s,
              source: source.to_s,
              note: note,
              expires_at: expires_at
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

        owner_class.transaction do
          # Lock a fresh copy so granting a feature never reloads or rejects a
          # caller that happens to have unrelated unsaved changes.
          owner_class.unscoped.lock.find(plan_owner.id)
          yield
        end
      end
    end

    private

    def expires_at_must_be_parseable
      raw_value = expires_at_before_type_cast
      return if raw_value.nil? || (raw_value.is_a?(String) && raw_value.blank?)
      return if expires_at.respond_to?(:to_time)

      errors.add(:expires_at, "must be a valid time")
    end
  end
end
