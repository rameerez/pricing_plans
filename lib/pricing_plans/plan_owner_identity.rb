# frozen_string_literal: true

module PricingPlans
  # Builds the identity Rails stores for polymorphic plan-owner associations.
  #
  # Rails stores an Active Record model's polymorphic_name (normally its STI
  # base class), not necessarily `record.class.name`. Keeping this in one place
  # prevents reads and writes from disagreeing for STI subclasses and respects
  # the host application's `store_full_class_name` configuration.
  module PlanOwnerIdentity
    module_function

    def type_for(plan_owner_or_class)
      plan_owner_class = plan_owner_or_class.is_a?(Class) ? plan_owner_or_class : plan_owner_or_class.class

      if plan_owner_class.respond_to?(:polymorphic_name)
        plan_owner_class.polymorphic_name
      else
        plan_owner_class.name
      end
    end

    def conditions_for(plan_owner)
      {
        plan_owner_type: type_for(plan_owner),
        plan_owner_id: plan_owner.respond_to?(:id) ? plan_owner.id : nil
      }
    end
  end
end
