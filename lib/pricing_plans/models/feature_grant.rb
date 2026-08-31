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

    scope :for_feature, ->(feature_key) { where(feature_key: feature_key.to_s) }
    scope :active, -> {
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

      def revoke_for!(plan_owner, feature_key, note: nil)
        ensure_table!

        active
          .where(owner_conditions(plan_owner).merge(feature_key: feature_key.to_s))
          .map { |grant| grant.revoke!(note: note) }
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
        { plan_owner_type: plan_owner.class.name, plan_owner_id: plan_owner.id }
      end
    end
  end
end
