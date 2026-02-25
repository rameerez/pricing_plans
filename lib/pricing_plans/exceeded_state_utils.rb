# frozen_string_literal: true

module PricingPlans
  # Shared utilities for checking and managing exceeded state.
  #
  # This module provides common logic for determining whether usage has exceeded
  # limits and for clearing stale exceeded flags. It is included by both
  # GraceManager (class methods) and StatusContext (instance methods) to ensure
  # consistent behavior.
  #
  # NOTE: Methods that modify state (`clear_exceeded_flags!`) are intentionally
  # included here. The design decision is that grace/block checks should be
  # "self-healing" - if usage drops below the limit, stale exceeded flags are
  # automatically cleared. This prevents situations where users remain incorrectly
  # flagged as exceeded after deleting resources or after plan upgrades.
  module ExceededStateUtils
    # Determine if usage has exceeded the limit based on the after_limit policy.
    #
    # For :grace_then_block, exceeded means strictly OVER the limit (>).
    # For :block_usage and :just_warn, exceeded means AT or over the limit (>=).
    #
    # This distinction exists because:
    # - :block_usage blocks creation of the Nth item (at limit = blocked)
    # - :grace_then_block allows the Nth item, only starting grace when OVER
    #
    # @param current_usage [Integer] Current usage count
    # @param limit_amount [Integer, Symbol] The configured limit (may be :unlimited)
    # @param after_limit [Symbol] The enforcement policy (:block_usage, :grace_then_block, :just_warn)
    # @return [Boolean] true if usage is considered exceeded for this policy
    def exceeded_now?(current_usage, limit_amount, after_limit:)
      # 0-of-0 is a special case: not considered exceeded for UX purposes
      return false if limit_amount.to_i.zero? && current_usage.to_i.zero?

      if after_limit == :grace_then_block
        current_usage > limit_amount.to_i
      else
        current_usage >= limit_amount.to_i
      end
    end

    # Clear exceeded and blocked flags from an enforcement state record.
    #
    # This is called when usage drops below the limit to "heal" stale state.
    # Uses update_columns for efficiency (skips validations/callbacks).
    #
    # @param state [EnforcementState] The state record to clear
    # @return [EnforcementState, nil] The updated state, or nil if no updates needed
    def clear_exceeded_flags!(state)
      return unless state

      updates = {}
      updates[:exceeded_at] = nil if state.exceeded_at.present?
      updates[:blocked_at] = nil if state.blocked_at.present?
      return state if updates.empty?

      updates[:updated_at] = Time.current
      state.update_columns(updates)
      state
    end
  end
end
