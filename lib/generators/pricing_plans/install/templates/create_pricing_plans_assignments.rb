# frozen_string_literal: true

class CreatePricingPlansAssignments < ActiveRecord::Migration[7.0]
  def change
    create_table :pricing_plans_assignments do |t|
      t.string :billable_type, null: false
      t.bigint :billable_id, null: false
      t.string :plan_key, null: false
      t.string :source, null: false, default: 'manual'
      
      t.timestamps
    end
    
    add_index :pricing_plans_assignments,
              [:billable_type, :billable_id],
              unique: true,
              name: 'idx_pricing_plans_assignments_unique'
              
    add_index :pricing_plans_assignments,
              :plan_key,
              name: 'idx_pricing_plans_assignments_plan'
  end
end