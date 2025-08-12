# frozen_string_literal: true

module PricingPlans
  module ViewHelpers
    module_function

    # Pure-data UI struct for Stimulus/JS pricing toggles
    # Returns keys:
    # - :monthly_price, :yearly_price (formatted labels)
    # - :monthly_price_cents, :yearly_price_cents
    # - :monthly_price_id, :yearly_price_id
    # - :free (boolean)
    # - :label (fallback label for non-numeric)
    def pricing_plan_ui_data(plan)
      pc_m = plan.monthly_price_components
      pc_y = plan.yearly_price_components
      {
        monthly_price: pc_m.label,
        yearly_price: pc_y.label,
        monthly_price_cents: pc_m.amount_cents,
        yearly_price_cents: pc_y.amount_cents,
        monthly_price_id: plan.monthly_price_id,
        yearly_price_id: plan.yearly_price_id,
        free: plan.free?,
        label: plan.price_label
      }
    end

    # CTA data resolution. Returns pure data: { text:, url:, method:, disabled:, reason: }
    # We keep this minimal and policy-free by default; host apps can layer policies.
    def pricing_plan_cta(plan, billable: nil, context: :marketing, current_plan: nil)
      text = plan.cta_text
      url = plan.cta_url(billable: billable)
      disabled = false
      reason = nil

      if current_plan && plan.key.to_sym == current_plan.key.to_sym
        disabled = true
        text = "Current Plan"
      end

      { text: text, url: url, method: :get, disabled: disabled, reason: reason }
    end
  end
end


