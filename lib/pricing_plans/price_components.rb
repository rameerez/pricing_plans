# frozen_string_literal: true

module PricingPlans
  # Pure-data value object describing a plan price in semantic parts.
  # UI-agnostic. Useful to render classic pricing typography and power JS toggles.
  PriceComponents = Struct.new(
    :present?,                 # boolean: true when numeric price is available
    :currency,                 # String: currency symbol, e.g. "$", "€"
    :amount,                   # String: human whole amount (no decimals) e.g. "29"
    :amount_cents,             # Integer: total cents e.g. 2900
    :interval,                 # Symbol: :day, :week, :month, :quarter or :year
    :label,                    # String: friendly label e.g. "$29/mo", "$54/qtr" or "Contact"
    :monthly_equivalent_cents, # Integer: amount per month, e.g. 1800 for $54/qtr
    :monthly_equivalent_label, # String: per-month label e.g. "$18/mo"
    keyword_init: true
  )
end
