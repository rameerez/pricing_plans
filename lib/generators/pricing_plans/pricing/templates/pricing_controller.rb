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

  # Optional Pay (Stripe) integration — quickstart example
  # Uncomment and add a route to make CTAs work out-of-the-box:
  #
  #   POST /pricing/subscribe?plan=pro
  #   rails g controller pricing subscribe --skip-routes
  #   config/routes.rb: post "pricing/subscribe", to: "pricing#subscribe", as: :pricing_subscribe
  #
  # def subscribe
  #   plan_key = params[:plan]&.to_sym
  #   plan = PricingPlans.registry.plan(plan_key)
  #   return redirect_to(pricing_path, alert: "Unknown plan") unless plan
  #   return redirect_to(pricing_path, alert: "Plan not purchasable") unless plan.stripe_price
  #
  #   billable = respond_to?(:current_user) && current_user&.respond_to?(:organization) ? current_user.organization : current_user
  #   return redirect_to(pricing_path, alert: "Sign in required") unless billable
  #
  #   # Requires the Pay gem to be installed and configured in your app.
  #   billable.set_payment_processor :stripe unless billable.respond_to?(:payment_processor) && billable.payment_processor
  #   price_id = plan.stripe_price.is_a?(Hash) ? (plan.stripe_price[:id] || plan.stripe_price.values.first) : plan.stripe_price
  #
  #   session = billable.payment_processor.checkout(
  #     mode: "subscription",
  #     line_items: [{ price: price_id }],
  #     success_url: root_url,
  #     cancel_url: pricing_url
  #   )
  #   redirect_to session.url, allow_other_host: true, status: :see_other
  # end
end
