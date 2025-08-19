# frozen_string_literal: true

require_relative "lib/pricing_plans/version"

Gem::Specification.new do |spec|
  spec.name = "pricing_plans"
  spec.version = PricingPlans::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]

  spec.summary = "Define and enforce pricing plan limits (entitlements, quotas, feature gating) in your Rails SaaS"
  spec.description = "Define and enforce pricing plan limits in your Rails SaaS (entitlements, quotas, feature gating). pricing_plans acts as your single source of truth for pricing plans. Define a pricing catalog with feature gating, persistent caps, per‑period allowances, grace periods, and get view/controller/model helpers. Seamless Stripe/Pay ergonomics and UI‑agnostic helpers to build pricing tables, plan usage meters, plan limit alerts, upgrade prompts, and more."
  spec.homepage = "https://github.com/rameerez/pricing_plans"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rameerez/pricing_plans"
  spec.metadata["changelog_uri"] = "https://github.com/rameerez/pricing_plans/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/rameerez/pricing_plans/issues"
  spec.metadata["documentation_uri"] = "https://github.com/rameerez/pricing_plans#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Core dependencies
  spec.add_dependency "activerecord", "~> 7.1", ">= 7.1.0"
  spec.add_dependency "activesupport", "~> 7.1", ">= 7.1.0"

  # Development dependencies
  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "sqlite3", "~> 2.1"
  spec.add_development_dependency "rubocop", "~> 1.0"
  spec.add_development_dependency "rubocop-minitest", "~> 0.35"
  spec.add_development_dependency "rubocop-performance", "~> 1.0"
end
