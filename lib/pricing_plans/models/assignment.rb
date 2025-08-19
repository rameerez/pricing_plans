# frozen_string_literal: true

module PricingPlans
  class Assignment < ActiveRecord::Base
    self.table_name = "pricing_plans_assignments"

    belongs_to :plan_owner, polymorphic: true

    validates :plan_owner, presence: true
    validates :plan_key, presence: true
    validates :source, presence: true
    validates :plan_owner_type, uniqueness: { scope: :plan_owner_id }

    validate :plan_exists_in_registry

    scope :manual, -> { where(source: "manual") }
    scope :for_plan, ->(plan_key) { where(plan_key: plan_key.to_s) }

    def plan
      Registry.plan(plan_key.to_sym)
    end

    def self.assign_plan_to(plan_owner, plan_key, source: "manual")
      assignment = find_or_initialize_by(
        plan_owner_type: plan_owner.class.name,
        plan_owner_id: plan_owner.id
      )

      assignment.assign_attributes(
        plan_key: plan_key.to_s,
        source: source.to_s
      )

      assignment.save!
      assignment
    end

    def self.remove_assignment_for(plan_owner)
      where(
        plan_owner_type: plan_owner.class.name,
        plan_owner_id: plan_owner.id
      ).destroy_all
    end

    private

    def plan_exists_in_registry
      return unless plan_key.present?

      unless Registry.plan_exists?(plan_key)
        errors.add(:plan_key, "#{plan_key} is not a defined plan")
      end
    end
  end
end
