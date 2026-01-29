# frozen_string_literal: true

module PricingPlans
  # Centralized callback dispatch module with error isolation.
  # Callbacks should never break the main operation - errors are logged but not raised.
  module Callbacks
    module_function

    # Dispatch a callback event with error isolation.
    # Callbacks should never break the main operation.
    #
    # @param event_type [Symbol] The event type (:warning, :grace_start, :block)
    # @param limit_key [Symbol] The limit key (e.g., :projects, :licenses)
    # @param args [Array] Arguments to pass to the callback
    def dispatch(event_type, limit_key, *args)
      handler = Registry.event_handlers.dig(event_type, limit_key)
      return unless handler.is_a?(Proc)

      execute_safely(handler, event_type, limit_key, *args)
    end

    # Execute callback with error isolation and arity handling.
    # Supports callbacks with 0, 1, 2, or variable arguments.
    #
    # @param handler [Proc] The callback to execute
    # @param event_type [Symbol] For logging purposes
    # @param limit_key [Symbol] For logging purposes
    # @param args [Array] Arguments to pass
    def execute_safely(handler, event_type, limit_key, *args)
      case handler.arity
      when 0
        handler.call
      when 1
        handler.call(args.first)
      when 2
        handler.call(*args.first(2))
      when -1, -2 # Variable arity (splat args)
        handler.call(*args)
      else
        handler.call(*args.first(handler.arity.abs))
      end
    rescue StandardError => e
      # Log but don't re-raise - callbacks should never break credit operations
      log_error("[PricingPlans] Callback error for #{event_type}:#{limit_key}: #{e.class}: #{e.message}")
      log_debug(e.backtrace&.join("\n"))
    end

    # Check warning thresholds and emit warning event if a new threshold is crossed.
    # This is the main entry point for automatic warning detection.
    #
    # @param plan_owner [Object] The plan owner (e.g., Organization)
    # @param limit_key [Symbol] The limit key
    # @param current_usage [Integer] Current usage count (after the action)
    # @param limit_amount [Integer] The configured limit
    def check_and_emit_warnings!(plan_owner, limit_key, current_usage, limit_amount)
      return if limit_amount == :unlimited || limit_amount.to_i.zero?

      percent_used = (current_usage.to_f / limit_amount) * 100
      thresholds = LimitChecker.warning_thresholds(plan_owner, limit_key)

      # Find the highest threshold that has been crossed
      crossed_threshold = thresholds.select { |t| percent_used >= (t * 100) }.max
      return unless crossed_threshold

      # Emit warning if this is a new higher threshold
      GraceManager.maybe_emit_warning!(plan_owner, limit_key, crossed_threshold)
    end

    # Check if limit is exceeded and handle grace state (for grace_then_block policy).
    # This is called after a successful model creation, so it only handles:
    # - :just_warn - emit additional warning
    # - :grace_then_block - start grace period if exceeded and not already in grace
    #
    # NOTE: Block events are NOT emitted here because this runs after successful creation.
    # Block events are emitted in Limitable validation when creation is actually blocked.
    #
    # @param plan_owner [Object] The plan owner
    # @param limit_key [Symbol] The limit key
    # @param current_usage [Integer] Current usage count
    # @param limit_config [Hash] The limit configuration from the plan
    def check_and_emit_limit_exceeded!(plan_owner, limit_key, current_usage, limit_config)
      return unless limit_config
      return if limit_config[:to] == :unlimited

      limit_amount = limit_config[:to].to_i
      return unless current_usage >= limit_amount

      case limit_config[:after_limit]
      when :just_warn
        # Just emit warning, don't track grace/block
        check_and_emit_warnings!(plan_owner, limit_key, current_usage, limit_amount)
      when :block_usage
        # Do NOT mark as blocked here - this callback runs after SUCCESSFUL creation.
        # Block events are emitted from validation when creation is actually blocked.
        nil
      when :grace_then_block
        # Start grace period if not already in grace/blocked
        unless GraceManager.grace_active?(plan_owner, limit_key) || GraceManager.should_block?(plan_owner, limit_key)
          GraceManager.mark_exceeded!(plan_owner, limit_key, grace_period: limit_config[:grace])
        end
      end
    end

    # Safe logging that works with or without Rails
    def log_error(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.error(message)
      elsif PricingPlans.configuration&.debug
        warn message
      end
    end

    def log_warn(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      elsif PricingPlans.configuration&.debug
        warn message
      end
    end

    def log_debug(message)
      return unless message

      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger&.debug?
        Rails.logger.debug(message)
      end
    end
  end
end
