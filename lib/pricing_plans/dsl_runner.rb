# frozen_string_literal: true

# Kept intentionally empty; DSL refinements must be activated lexically by the
# caller (e.g., in the generated initializer). We avoid using refinements inside
# methods due to Ruby restrictions.
module PricingPlans
  module DSLRunner
  end
end
