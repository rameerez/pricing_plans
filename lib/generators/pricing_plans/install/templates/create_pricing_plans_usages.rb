# frozen_string_literal: true

class CreatePricingPlansUsages < ActiveRecord::Migration[7.0]
  def change
    create_table :pricing_plans_usages do |t|
      t.string :billable_type, null: false
      t.bigint :billable_id, null: false
      t.string :limit_key, null: false
      t.datetime :period_start, null: false
      t.datetime :period_end, null: false
      t.bigint :used, default: 0, null: false
      t.datetime :last_used_at
      
      t.timestamps
    end
    
    add_index :pricing_plans_usages,
              [:billable_type, :billable_id, :limit_key, :period_start],
              unique: true,
              name: 'idx_pricing_plans_usages_unique'
              
    add_index :pricing_plans_usages,
              [:billable_type, :billable_id],
              name: 'idx_pricing_plans_usages_billable'
              
    add_index :pricing_plans_usages,
              [:period_start, :period_end],
              name: 'idx_pricing_plans_usages_period'
  end
end