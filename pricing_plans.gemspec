# frozen_string_literal: true

require_relative "lib/pricing_plans/version"

Gem::Specification.new do |spec|
  spec.name = "pricing_plans"
  spec.version = PricingPlans::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]

  spec.summary = "Plan catalog + enforcement brain for Rails SaaS applications"
  spec.description = "Define plans, feature flags, and limits with grace periods in one Ruby file. Integrates seamlessly with Pay and usage_credits for complete billing solution."
  spec.homepage = "https://github.com/rameerez/pricing_plans"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rameerez/pricing_plans"
  spec.metadata["changelog_uri"] = "https://github.com/rameerez/pricing_plans/blob/main/CHANGELOG.md"

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
  spec.add_dependency "activerecord", ">= 7.1.0"
  spec.add_dependency "activesupport", ">= 7.1.0"

  # Development dependencies
  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "sqlite3", "~> 2.1"
  spec.add_development_dependency "rubocop", "~> 1.0"
  spec.add_development_dependency "rubocop-minitest", "~> 0.35"
  spec.add_development_dependency "rubocop-performance", "~> 1.0"
end
