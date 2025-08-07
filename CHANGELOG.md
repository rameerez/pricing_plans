# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-08-07

### Added

**Core Features**
- Plan catalog configuration system with English-first DSL
- Feature flags (boolean allows/disallows)
- Persistent caps (max concurrent resources like projects, seats)
- Per-period discrete allowances (e.g., "3 custom models/month")
- Grace period enforcement with configurable behaviors
- Event system for warning/grace/block notifications

**Configuration & DSL**
- `PricingPlans.configure` block for one-file configuration
- Plan definition with name, description, bullets, pricing
- `Integer#max` refinement for clean DSL (`5.max`)
- Support for Stripe price IDs and manual pricing
- Flexible period cycles (billing, calendar month/week/day, custom)

**Database & Models**
- Three-table schema for enforcement states, usage counters, assignments
- `EnforcementState` model for grace period tracking with row-level locking
- `Usage` model for per-period counters with atomic upserts
- `Assignment` model for manual plan overrides

**Controller Integration**
- `require_plan_limit!` guard returning rich Result objects
- `require_feature!` guard with FeatureDenied exception
- Automatic grace period management and event emission
- Race-safe limit checking with retries

**Model Integration**
- `Limitable` mixin for ActiveRecord models
- `limited_by` macro for automatic usage tracking
- Real-time persistent caps (no counter caches needed)
- Automatic per-period counter increments

**View Helpers & UI**
- Complete pricing table rendering
- Usage meters with progress bars  
- Limit banners with warnings/grace/blocked states
- Plan information helpers (current plan, feature checks)

**Pay Integration**
- Automatic plan resolution from Stripe subscriptions
- Support for trial, grace, and active subscription states
- Price ID to plan mapping
- Billing cycle anchor integration for periods

**usage_credits Integration**  
- Credit inclusion display in pricing tables
- Boot-time linting to prevent limit/credit collisions
- Operation validation against usage_credits registry
- Clean separation of concerns (credits vs discrete limits)

**Generators**
- Install generator with migrations and initializer template
- Pricing generator with views, controller, and CSS
- Comprehensive Tailwind-friendly styling

**Architecture & Performance**
- Rails Engine for seamless integration
- Autoloading with proper namespacing
- Row-level locking for race condition prevention  
- Efficient query patterns with proper indexing
- Memoization and caching where appropriate

### Technical Details

- Ruby 3.2+ requirement  
- Rails 7.1+ requirement (ActiveRecord, ActiveSupport)
- PostgreSQL optimized (with fallbacks for other databases)
- Comprehensive error handling and validation
- Thread-safe implementation throughout
