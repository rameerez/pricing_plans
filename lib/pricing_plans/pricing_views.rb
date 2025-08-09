# frozen_string_literal: true

module PricingPlans
  # Minimal drop-in view entry points. These render engine-provided partials
  # with minimal locals so host apps don't need plumbing.
  module PricingViews
    extend self

    # Renders pricing cards. Context can be :marketing or :dashboard.
    # Expects a view context (ActionView) via `view:` and optional billable for dashboard.
    def pricing_cards(view:, context: :marketing, billable: nil)
      collection = if context == :dashboard && billable
        PricingPlans.for_dashboard(billable)
      else
        PricingPlans.for_marketing
      end
      view.render(partial: "pricing_plans/pricing_cards", locals: { context: context, billable: billable, data: collection })
    end

    # Composite usage widget for commonly grouped limits.
    def usage_widget(view:, billable:, limits: [:products, :licenses, :activations])
      view.render(partial: "pricing_plans/usage_widget", locals: { billable: billable, limits: limits })
    end

    # Overage banner across multiple limits.
    def overage_banner(view:, billable:, limits: [:products, :licenses, :activations])
      view.render(partial: "pricing_plans/overage_banner", locals: { billable: billable, limits: limits })
    end
  end
end
