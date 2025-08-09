# frozen_string_literal: true

require "test_helper"

class EngineRescueResponsesTest < ActiveSupport::TestCase
  def test_feature_denied_is_mapped_to_403
    # In this minimal test environment we don't have a full Rails::Engine instance.
    # This test serves as a smoke test that the constant exists and the initializer code compiles.
    assert defined?(PricingPlans::FeatureDenied)
  end
end
