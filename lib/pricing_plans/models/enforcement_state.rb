# frozen_string_literal: true

module PricingPlans
  class EnforcementState < ActiveRecord::Base
    self.table_name = "pricing_plans_enforcement_states"
    
    belongs_to :billable, polymorphic: true
    
    validates :limit_key, presence: true
    validates :billable_type, :billable_id, :limit_key, uniqueness: { scope: [:billable_type, :billable_id] }
    
    scope :exceeded, -> { where.not(exceeded_at: nil) }
    scope :blocked, -> { where.not(blocked_at: nil) }
    scope :in_grace, -> { exceeded.where(blocked_at: nil) }
    
    def exceeded?
      exceeded_at.present?
    end
    
    def blocked?
      blocked_at.present?
    end
    
    def in_grace?
      exceeded? && !blocked?
    end
    
    def grace_ends_at
      return nil unless exceeded_at && grace_period
      exceeded_at + grace_period
    end
    
    def grace_expired?
      return false unless grace_ends_at
      Time.current >= grace_ends_at
    end
    
    private
    
    def grace_period
      # This will be set by the GraceManager based on the plan configuration
      data&.dig("grace_period")&.seconds
    end
  end
end