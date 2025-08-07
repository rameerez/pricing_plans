# frozen_string_literal: true

class CreatePricingPlansEnforcementStates < ActiveRecord::Migration[7.0]
  def change
    create_table :pricing_plans_enforcement_states do |t|
      t.string :billable_type, null: false
      t.bigint :billable_id, null: false
      t.string :limit_key, null: false
      t.datetime :exceeded_at
      t.datetime :blocked_at
      t.decimal :last_warning_threshold, precision: 3, scale: 2
      t.datetime :last_warning_at
      t.jsonb :data, default: {}
      
      t.timestamps
    end
    
    add_index :pricing_plans_enforcement_states, 
              [:billable_type, :billable_id, :limit_key], 
              unique: true, 
              name: 'idx_pricing_plans_enforcement_unique'
              
    add_index :pricing_plans_enforcement_states,
              [:billable_type, :billable_id],
              name: 'idx_pricing_plans_enforcement_billable'
              
    add_index :pricing_plans_enforcement_states,
              :exceeded_at,
              where: "exceeded_at IS NOT NULL",
              name: 'idx_pricing_plans_enforcement_exceeded'
  end
end