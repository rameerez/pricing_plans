# frozen_string_literal: true

module PricingPlans
  class Assignment < ActiveRecord::Base
    self.table_name = "pricing_plans_assignments"
    
    belongs_to :billable, polymorphic: true
    
    validates :billable, presence: true
    validates :plan_key, presence: true
    validates :source, presence: true
    validates :billable_type, uniqueness: { scope: :billable_id }
    
    validate :plan_exists_in_registry
    
    scope :manual, -> { where(source: "manual") }
    scope :for_plan, ->(plan_key) { where(plan_key: plan_key.to_s) }
    
    def plan
      Registry.plan(plan_key.to_sym)
    end
    
    def self.assign_plan_to(billable, plan_key, source: "manual")
      assignment = find_or_initialize_by(
        billable_type: billable.class.name,
        billable_id: billable.id
      )
      
      assignment.assign_attributes(
        plan_key: plan_key.to_s,
        source: source.to_s
      )
      
      assignment.save!
      assignment
    end
    
    def self.remove_assignment_for(billable)
      where(
        billable_type: billable.class.name,
        billable_id: billable.id
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