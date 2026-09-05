# frozen_string_literal: true

module PricingPlans
  class FeatureGrantConflict < Error; end

  class FeatureLimitExceeded < FeatureDenied
    attr_reader :limit_key, :allowed, :requested

    def initialize(feature_key:, plan_owner:, limit_key:, allowed:, requested:)
      @limit_key = limit_key
      @allowed = allowed
      @requested = requested
      super("#{feature_key.to_s.humanize}: #{limit_key.to_s.humanize.downcase} limit exceeded " \
            "(#{requested} requested, #{allowed} allowed).", feature_key: feature_key, plan_owner: plan_owner)
    end
  end

  # One snapshot for presentation and preflight checks. Writes must use
  # PlanOwner#with_feature_access! to resolve again under the owner row lock.
  class FeatureAccess
    MAX_INTEGER = (2**63) - 1
    attr_reader :owner, :feature_key, :source, :grant, :limits

    def self.validate_amount!(amount)
      return amount if amount.is_a?(Integer) && amount.between?(0, MAX_INTEGER)

      raise ArgumentError, "usage must be a nonnegative integer no larger than #{MAX_INTEGER}"
    end

    def self.normalize_limits(limits)
      raise ArgumentError, "limits must be a Hash" unless limits.is_a?(Hash)

      limits.each_with_object({}) do |(key, amount), result|
        unless (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s.match?(/\A[a-z][a-z0-9_]*\z/)
          raise ArgumentError, "limit keys must be lowercase names such as storage_bytes"
        end
        raise ArgumentError, "duplicate limit #{key}" if result.key?(key.to_s)

        result[key.to_s] = if amount == :unlimited || amount == "unlimited"
                             "unlimited"
                           else
                             validate_amount!(amount)
                           end
      end
    end

    # Named limits belong to a pass. Plan and grandfather access carry none:
    # the gem answers "is this owner entitled?", and the app owns its plan
    # quotas the way it always has.
    def initialize(owner, feature_key)
      @owner = owner
      @feature_key = feature_key.to_sym
      @source = owner.feature_entitlement_source(@feature_key)
      @grant = owner.feature_grants.active.for_feature(@feature_key).first if source == :grant
      @source = nil if source == :grant && !grant
      @limits = (grant ? grant.pass_limits : {}).freeze
    end

    def allowed? = !source.nil?
    def expires_at = grant&.expires_at
    def usage_limit = grant&.pass_usage_limit
    def usage_count = grant ? grant.pass_usage_count : 0

    def limit(key)
      value = limits.fetch(key.to_s, "unlimited")
      value == "unlimited" ? :unlimited : value
    end

    def remaining_allowance
      usage_limit ? [usage_limit - usage_count, 0].max : :unlimited
    end

    def available?(amount: 0, usage: {})
      check!(amount: amount, usage: usage)
      true
    rescue FeatureDenied
      false
    end

    def check!(amount: 0, usage: {})
      self.class.validate_amount!(amount)
      raise ArgumentError, "usage must be a Hash" unless usage.is_a?(Hash)

      unless allowed?
        raise FeatureDenied.new("#{feature_key.to_s.humanize} is not available.",
                                feature_key: feature_key, plan_owner: owner)
      end

      check_capacity!(usage)
      check_limit!(:usage, usage_limit, usage_count + amount) if usage_limit && amount.positive?
      self
    end

    private

    def check_capacity!(usage)
      usage.each do |key, value|
        self.class.validate_amount!(value)
        check_limit!(key.to_sym, limit(key), value)
      end
    end

    def check_limit!(key, allowed, requested)
      return if allowed == :unlimited || requested <= allowed

      raise FeatureLimitExceeded.new(feature_key: feature_key, plan_owner: owner,
                                     limit_key: key, allowed: allowed, requested: requested)
    end
  end
end
