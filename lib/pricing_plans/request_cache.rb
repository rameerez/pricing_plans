# frozen_string_literal: true

module PricingPlans
  # Lightweight per-request/per-thread cache to avoid repeated plan/window resolution
  class RequestCache
    class << self
      def store
        if defined?(RequestStore) && RequestStore.respond_to?(:store)
          RequestStore.store[:pricing_plans_cache] ||= {}
        else
          Thread.current[:pricing_plans_cache] ||= {}
        end
      end

      def fetch(key)
        cache = store
        return cache[key] if cache.key?(key)
        cache[key] = yield
      end

      def clear!
        if defined?(RequestStore) && RequestStore.respond_to?(:store)
          RequestStore.store[:pricing_plans_cache] = {}
        else
          Thread.current[:pricing_plans_cache] = {}
        end
      end
    end
  end
end
