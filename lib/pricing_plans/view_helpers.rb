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
        concat(content_tag :div, class: "pricing-plans-meter__label" do
          "#{limit_key.to_s.humanize}: #{current_usage} / #{limit_amount}"
        end)
        
        concat(content_tag :div, class: "pricing-plans-meter__bar" do
          content_tag :div, "", 
            class: "pricing-plans-meter__fill",
            style: "width: #{[percent_used, 100].min}%",
            data: { percent: percent_used }
        end)
      end
    end
    
    def plan_pricing_table(highlight: false, **html_options)
      css_classes = ["pricing-plans-table"]
      css_classes << html_options.delete(:class) if html_options[:class]
      
      highlighted_plan_key = highlight ? Registry.configuration.highlighted_plan : nil
      
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
  end
end