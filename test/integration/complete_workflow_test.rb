# frozen_string_literal: true

require "test_helper"

class CompleteWorkflowTest < ActiveSupport::TestCase
  def test_complete_project_limit_workflow_with_grace_period
    org = create_organization
    
    # Start within limit
    assert_equal 1, PricingPlans::LimitChecker.remaining(org, :projects)
    
    # Create project - should succeed and be at limit
    project = org.projects.create!(name: "Project 1")
    assert_equal 0, PricingPlans::LimitChecker.remaining(org, :projects)
    
    # Try to create another project - should trigger grace period
    result = PricingPlans::ControllerGuards.new.require_plan_limit!(:projects, billable: org)
    assert result.grace?
    assert_match(/grace period/, result.message)
    
    # Should have enforcement state
    state = PricingPlans::EnforcementState.find_by(billable: org, limit_key: "projects")
    assert state.exceeded?
    refute state.blocked?
    
    # During grace period, can still create (but get warnings)
    project2 = org.projects.create!(name: "Project 2") 
    assert project2.persisted?
    
    # Advance past grace period
    travel_to_time(8.days.from_now) do
      # Now should be blocked
      result = PricingPlans::ControllerGuards.new.require_plan_limit!(:projects, billable: org)
      assert result.blocked?
      assert_match(/limit/, result.message)
      
      # State should be updated to blocked
      state.reload
      assert state.blocked?
    end
  end

  def test_plan_upgrade_workflow_with_stripe_subscription
    org = create_organization
    
    # Start on free plan
    assert_equal :free, PricingPlans::PlanResolver.effective_plan_for(org).key
    assert_equal 1, PricingPlans::LimitChecker.limit_amount(org, :projects)
    
    # Simulate Stripe subscription activation
    org.pay_subscription = { 
      active: true, 
      processor_plan: "price_pro_123" 
    }
    
    # Now on pro plan with higher limits
    assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
    assert_equal 10, PricingPlans::LimitChecker.limit_amount(org, :projects)
    
    # Can create more projects
    5.times { |i| org.projects.create!(name: "Project #{i}") }
    assert_equal 5, PricingPlans::LimitChecker.remaining(org, :projects)
    
    # Feature access granted
    assert_nothing_raised do
      PricingPlans::ControllerGuards.new.require_feature!(:api_access, billable: org)
    end
  end

  def test_per_period_limit_workflow_across_period_boundary
    # Assign to pro plan which has custom_models limit
    PricingPlans::Assignment.assign_plan_to(create_organization, :pro)
    org = Organization.first
    
    travel_to_time(Time.parse("2025-01-15 12:00:00 UTC")) do
      # Create custom models up to limit (3 for pro plan)
      3.times { |i| org.custom_models.create!(name: "Model #{i}") }
      
      # Should be at limit
      assert_equal 0, PricingPlans::LimitChecker.remaining(org, :custom_models)
      
      # Can't create more this period
      result = PricingPlans::ControllerGuards.new.require_plan_limit!(:custom_models, billable: org)
      assert result.grace?  # Pro plan has grace_then_block
    end
    
    # Move to next month
    travel_to_time(Time.parse("2025-02-01 12:00:00 UTC")) do
      # Limit should reset
      assert_equal 3, PricingPlans::LimitChecker.remaining(org, :custom_models)
      
      # Can create models again
      result = PricingPlans::ControllerGuards.new.require_plan_limit!(:custom_models, billable: org)
      assert result.ok?
      
      org.custom_models.create!(name: "Model in new period")
      assert_equal 2, PricingPlans::LimitChecker.remaining(org, :custom_models)
    end
  end

  def test_warning_threshold_workflow
    org = create_organization
    warning_events = []
    
    # Mock event handler
    PricingPlans::Registry.stub(:emit_event, ->(type, key, *args) {
      warning_events << { type: type, key: key, args: args } if type == :warning
    }) do
      # Create projects to trigger warnings at different thresholds
      # Free plan allows 1 project with thresholds at [0.6, 0.8, 0.95]
      
      # At 60% (would need fractional projects, so simulate with usage)
      state = PricingPlans::EnforcementState.create!(
        billable: org,
        limit_key: "projects",
        last_warning_threshold: 0.0
      )
      
      # Manually trigger warnings to test thresholds
      PricingPlans::GraceManager.maybe_emit_warning!(org, :projects, 0.6)
      assert_equal 1, warning_events.size
      assert_equal 0.6, warning_events.last[:args][1]
      
      PricingPlans::GraceManager.maybe_emit_warning!(org, :projects, 0.8)
      assert_equal 2, warning_events.size
      assert_equal 0.8, warning_events.last[:args][1]
      
      # Same threshold shouldn't emit again
      PricingPlans::GraceManager.maybe_emit_warning!(org, :projects, 0.8)
      assert_equal 2, warning_events.size
    end
  end

  def test_concurrent_project_creation_at_limit
    org = create_organization
    
    # Fill up to limit
    org.projects.create!(name: "Existing Project")
    
    # Try to create multiple projects concurrently
    threads = []
    results = []
    
    5.times do |i|
      threads << Thread.new do
        begin
          result = PricingPlans::ControllerGuards.new.require_plan_limit!(:projects, billable: org)
          results << result.state
          
          if result.ok? || result.grace?
            org.projects.create!(name: "Concurrent Project #{i}")
          end
        rescue => e
          results << :error
        end
      end
    end
    
    threads.each(&:join)
    
    # Should have consistent behavior - all should get grace or blocked
    # (exact behavior depends on timing, but should be consistent)
    unique_states = results.uniq
    
    # Most should be in grace state since we exceeded the limit
    assert_includes unique_states, :grace
  end

  def test_complete_feature_access_workflow
    org = create_organization
    
    # Free plan doesn't allow API access
    error = assert_raises(PricingPlans::FeatureDenied) do
      PricingPlans::ControllerGuards.new.require_feature!(:api_access, billable: org)
    end
    assert_match(/api access/i, error.message)
    assert_match(/pro/i, error.message)  # Should mention upgrade to Pro
    
    # Upgrade to pro plan
    PricingPlans::Assignment.assign_plan_to(org, :pro)
    
    # Now API access should work
    assert_nothing_raised do
      PricingPlans::ControllerGuards.new.require_feature!(:api_access, billable: org)
    end
  end

  def test_enterprise_unlimited_workflow
    PricingPlans::Assignment.assign_plan_to(create_organization, :enterprise)
    org = Organization.first
    
    # Should have unlimited projects
    assert_equal :unlimited, PricingPlans::LimitChecker.limit_amount(org, :projects)
    assert_equal :unlimited, PricingPlans::LimitChecker.remaining(org, :projects)
    
    # Can create many projects without limits
    10.times { |i| org.projects.create!(name: "Enterprise Project #{i}") }
    
    # Still unlimited
    assert_equal :unlimited, PricingPlans::LimitChecker.remaining(org, :projects)
    
    # Never triggers limit checks
    result = PricingPlans::ControllerGuards.new.require_plan_limit!(:projects, billable: org)
    assert result.ok?
    assert_match(/unlimited/i, result.message)
  end

  def test_manual_plan_assignment_override_workflow
    org = create_organization(
      pay_subscription: { active: true, processor_plan: "price_pro_123" }
    )
    
    # Should be on pro plan via subscription
    assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
    
    # But subscription overrides manual assignment
    PricingPlans::Assignment.assign_plan_to(org, :enterprise)
    
    # Still on pro plan (Pay takes precedence)
    assert_equal :pro, PricingPlans::PlanResolver.effective_plan_for(org).key
    
    # Remove subscription
    org.pay_subscription = { active: false }
    
    # Now manual assignment takes effect
    assert_equal :enterprise, PricingPlans::PlanResolver.effective_plan_for(org).key
  end

  def test_grace_period_expiration_workflow
    org = create_organization
    events = []
    
    PricingPlans::Registry.stub(:emit_event, ->(type, key, *args) {
      events << { type: type, key: key, args: args }
    }) do
      travel_to_time(Time.parse("2025-01-01 12:00:00 UTC")) do
        # Exceed limit
        org.projects.create!(name: "Project 1")
        
        result = PricingPlans::ControllerGuards.new.require_plan_limit!(:projects, billable: org)
        assert result.grace?
        
        # Should have emitted grace_start event
        grace_events = events.select { |e| e[:type] == :grace_start }
        assert_equal 1, grace_events.size
        
        # During grace period
        travel_to_time(Time.parse("2025-01-05 12:00:00 UTC")) do
          result = PricingPlans::ControllerGuards.new.require_plan_limit!(:projects, billable: org)
          assert result.grace?
        end
        
        # After grace expires
        travel_to_time(Time.parse("2025-01-08 12:00:01 UTC")) do
          result = PricingPlans::ControllerGuards.new.require_plan_limit!(:projects, billable: org)
          assert result.blocked?
          
          # Should have emitted block event
          block_events = events.select { |e| e[:type] == :block }
          assert_equal 1, block_events.size
        end
      end
    end
  end

  private

  def travel_to_time(time)
    Time.stub(:current, time) do
      yield
    end
  end
  
  # Include controller guards for testing
  include PricingPlans::ControllerGuards
end