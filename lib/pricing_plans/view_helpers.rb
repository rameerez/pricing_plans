# frozen_string_literal: true

module PricingPlans
  module ViewHelpers
    def plan_limit_banner(limit_key, billable:, **html_options)
      result = require_plan_limit!(limit_key, billable: billable, by: 0)
      return unless result.warning? || result.grace? || result.blocked?

      css_classes = ["pricing-plans-banner", "pricing-plans-banner--#{result.state}"]
      css_classes << html_options.delete(:class) if html_options[:class]

      content_tag :div, class: css_classes.join(" "), **html_options do
        content_tag(:span, result.icon, class: "pricing-plans-banner__icon") +
        content_tag(:span, result.message, class: "pricing-plans-banner__message")
      end
    rescue FeatureDenied
      # No banner for feature denials
      nil
    end

    def plan_usage_meter(limit_key, billable:, **html_options)
      plan = PlanResolver.effective_plan_for(billable)
      limit_config = plan&.limit_for(limit_key)
      return unless limit_config
      return if limit_config[:to] == :unlimited

      current_usage = LimitChecker.current_usage_for(billable, limit_key)
      limit_amount = limit_config[:to]
      percent_used = LimitChecker.percent_used(billable, limit_key)

      css_classes = ["pricing-plans-meter"]
      css_classes << html_options.delete(:class) if html_options[:class]

      content_tag :div, class: css_classes.join(" "), **html_options do
        concat(
          content_tag(:div, class: "pricing-plans-meter__label") do
            "#{limit_key.to_s.humanize}: #{current_usage} / #{limit_amount}"
          end
        )

        concat(
          content_tag(:div, class: "pricing-plans-meter__bar") do
            content_tag :div, "",
              class: "pricing-plans-meter__fill",
              style: "width: #{[percent_used, 100].min}%",
              data: { percent: percent_used }
          end
        )
      end
    end

    def plan_pricing_table(highlight: false, **html_options)
      css_classes = ["pricing-plans-table"]
      css_classes << html_options.delete(:class) if html_options[:class]

      highlighted_plan_key = nil
      if highlight
        # Prefer explicit config; fall back to a plan marked highlighted in DSL
        highlighted_plan_key = Registry.configuration.highlighted_plan
        highlighted_plan_key ||= Registry.plans.values.find(&:highlighted?)&.key
      end

      content_tag :div, class: css_classes.join(" "), **html_options do
        Registry.plans.values.map do |plan|
          render_plan_card(plan, highlighted: plan.key == highlighted_plan_key)
        end.join.html_safe
      end
    end

    def current_plan_name(billable)
      plan = PlanResolver.effective_plan_for(billable)
      plan&.name || "Unknown"
    end

    def plan_allows?(billable, feature_key)
      plan = PlanResolver.effective_plan_for(billable)
      plan&.allows_feature?(feature_key) || false
    end

    def plan_limit_remaining(billable, limit_key)
      LimitChecker.remaining(billable, limit_key)
    end

    def plan_limit_percent_used(billable, limit_key)
      LimitChecker.percent_used(billable, limit_key)
    end

    def current_pricing_plan(billable)
      PlanResolver.effective_plan_for(billable)
    end

    def plan_limit_status(limit_key, billable:)
      plan = PlanResolver.effective_plan_for(billable)
      limit_config = plan&.limit_for(limit_key)
      return { configured: false } unless limit_config

      usage = LimitChecker.current_usage_for(billable, limit_key, limit_config)
      limit_amount = limit_config[:to]
      percent = LimitChecker.percent_used(billable, limit_key)
      grace = GraceManager.grace_active?(billable, limit_key)
      blocked = GraceManager.should_block?(billable, limit_key)

      {
        configured: true,
        limit_key: limit_key.to_sym,
        limit_amount: limit_amount,
        current_usage: usage,
        percent_used: percent,
        grace_active: grace,
        grace_ends_at: GraceManager.grace_ends_at(billable, limit_key),
        blocked: blocked,
        after_limit: limit_config[:after_limit],
        per: !!limit_config[:per]
      }
    end

    # Render a minimal partial-like snippet for admin visibility. In real Rails apps,
    # apps can replace with their own partial; this provides a sensible default.
    def render_plan_limit_status(limit_key, billable:, **html_options)
      status = plan_limit_status(limit_key, billable: billable)
      return "".html_safe unless status[:configured]

      css = ["pricing-plans-status", (status[:blocked] ? "is-blocked" : (status[:grace_active] ? "is-grace" : "is-ok"))]
      css << html_options.delete(:class) if html_options[:class]

      content_tag :div, class: css.join(" "), **html_options do
        parts = []
        parts << content_tag(:strong, limit_key.to_s.humanize)
        parts << content_tag(:span, "#{status[:current_usage]} / #{status[:limit_amount]}") unless status[:limit_amount] == :unlimited
        parts << content_tag(:span, "Unlimited") if status[:limit_amount] == :unlimited
        parts << content_tag(:span, "#{status[:percent_used].round(1)}%")
        if status[:grace_active]
          ends = status[:grace_ends_at]&.utc&.iso8601
          parts << content_tag(:span, "Grace ends at #{ends}", class: "pricing-plans-status__grace")
        end
        parts.join(" ").html_safe
      end
    end

    private

    def render_plan_card(plan, highlighted: false)
      css_classes = ["pricing-plans-card"]
      css_classes << "pricing-plans-card--highlighted" if highlighted

      content_tag :div, class: css_classes.join(" ") do
        concat(render_plan_header(plan))
        concat(render_plan_price(plan))
        concat(render_plan_features(plan))
        concat(render_plan_credits(plan))
        concat(render_plan_cta(plan))
      end
    end

    def render_plan_header(plan)
      content_tag :div, class: "pricing-plans-card__header" do
        concat(content_tag :h3, plan.name, class: "pricing-plans-card__title")
        if plan.description
          concat(content_tag :p, plan.description, class: "pricing-plans-card__description")
        end
      end
    end

    def render_plan_price(plan)
      content_tag :div, class: "pricing-plans-card__price" do
        if plan.price_string
          content_tag :span, plan.price_string, class: "pricing-plans-card__price-text"
        elsif plan.price
          if plan.price.zero?
            content_tag :span, "Free", class: "pricing-plans-card__price-text"
          else
            content_tag :span, class: "pricing-plans-card__price-amount" do
              "$#{plan.price}"
            end
          end
        elsif plan.stripe_price
          # In a real implementation, you'd fetch the price from Stripe
          content_tag :span, "See Stripe", class: "pricing-plans-card__price-text"
        end
      end
    end

    def render_plan_features(plan)
      return unless plan.bullets.any?

      content_tag :ul, class: "pricing-plans-card__features" do
        plan.bullets.map do |bullet|
          content_tag :li, bullet
        end.join.html_safe
      end
    end

    def render_plan_credits(plan)
      return unless plan.credit_inclusions.any?

      content_tag :div, class: "pricing-plans-card__credits" do
        content_tag :h4, "Included Credits:", class: "pricing-plans-card__credits-title" do
          plan.credit_inclusions.map do |operation_key, inclusion|
            content_tag :div, class: "pricing-plans-card__credit-item" do
              "#{number_with_delimiter(inclusion[:amount])} #{operation_key.to_s.humanize.downcase}"
            end
          end.join.html_safe
        end
      end
    end

    def render_plan_cta(plan)
      content_tag :div, class: "pricing-plans-card__cta" do
        # This would typically include upgrade/subscribe buttons
        # For now, just a placeholder
        content_tag :button, "Choose Plan",
          class: "pricing-plans-card__button",
          data: { plan: plan.key }
      end
    end
    # Optional helper: generate a checkout URL via Pay for a plan that has a stripe_price.
    # This is OPINIONATED and expects you pass a block that knows how to
    # create the checkout session in your app. We keep Pay optional:
    # - If Pay is absent or the app doesn't pass a generator block, returns nil.
    # - Usage:
    #   checkout_url = pricing_plans_cta_url_for(plan, current_user) do |billable, plan|
    #     # Your app code: create Pay checkout and return its URL
    #     billable.set_payment_processor(:stripe) unless billable.payment_processor
    #     session = billable.payment_processor.checkout(mode: "subscription", line_items: [{ price: plan.stripe_price[:id] || plan.stripe_price }], success_url: root_url, cancel_url: root_url)
    #     session.url
    #   end
    #   # Then set plan.cta_url(checkout_url) or use directly in link_to
    def pricing_plans_cta_url_for(plan, billable, &block)
      return nil unless plan&.stripe_price
      return nil unless PricingPlans::PaySupport.pay_available?
      return nil unless billable
      return nil unless block_given?

      block.arity == 2 ? yield(billable, plan) : yield(billable)
    rescue StandardError
      nil
    end

    # Magical opt-in: when enabled via config.auto_cta_with_pay = true, we try to auto-derive CTA URL.
    # - For plans with stripe_price and when Pay is available, we call the provided generator block once per request
    #   to produce a CTA URL. If generation fails, we fall back to nil.
    # - Apps opt-in and provide the generator proc once, e.g. in a helper or initializer:
    #     PricingPlans::Registry.configuration.auto_cta_with_pay = ->(billable, plan, view) { ... return url }
    #   or set a controller/view instance variable to a proc and pass it explicitly.
    def pricing_plans_auto_cta_url(plan, billable, generator_proc = nil)
      return nil unless plan&.stripe_price
      return nil unless PricingPlans::PaySupport.pay_available?

      gen = generator_proc || PricingPlans::Registry.configuration.auto_cta_with_pay
      return nil unless gen

      if gen.respond_to?(:call)
        # Arity variants: (billable, plan, view) | (billable, plan) | (billable)
        case gen.arity
        when 3 then gen.call(billable, plan, self)
        when 2 then gen.call(billable, plan)
        else        gen.call(billable)
        end
      else
        nil
      end
    rescue StandardError
      nil
    end
  end
end
