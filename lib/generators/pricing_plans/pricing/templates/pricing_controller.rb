# frozen_string_literal: true

class PricingController < ApplicationController
  def index
    @plans = PricingPlans::Registry.plans.values
    @highlighted_plan = PricingPlans::Registry.highlighted_plan
    
    # If user is authenticated, show their current plan
    if respond_to?(:current_user) && current_user
      billable = current_user.respond_to?(:organization) ? current_user.organization : current_user
      @current_plan = PricingPlans::PlanResolver.effective_plan_for(billable)
    end
  end
end