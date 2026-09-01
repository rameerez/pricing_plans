# frozen_string_literal: true

# SimpleCov configuration file (auto-loaded before test suite)
# This keeps test_helper.rb clean and follows best practices

SimpleCov.configure do
  # Use SimpleFormatter for terminal-only output (no HTML generation)
  formatter SimpleCov::Formatter::SimpleFormatter

  # Track coverage for the lib directory (gem source code)
  skip "/test/"

  # Track the lib and app directories
  cover "{lib,app}/**/*.rb"

  # Enable branch coverage for more detailed metrics
  enable_coverage :branch

  # Set minimum coverage threshold to prevent coverage regression
  minimum_coverage line: 80, branch: 65

  # Disambiguate parallel test runs
  test_env_number = ENV.fetch("TEST_ENV_NUMBER", nil)
  command_name "Job #{test_env_number}" if test_env_number
end

# Print coverage summary to terminal after tests complete
SimpleCov.at_exit do
  SimpleCov.result.format!
  puts "\n#{'=' * 60}"
  puts "COVERAGE SUMMARY"
  puts "=" * 60
  puts "Line Coverage:   #{SimpleCov.result.covered_percent.round(2)}%"
  puts "Branch Coverage: #{SimpleCov.result.coverage_statistics[:branch]&.percent&.round(2) || 'N/A'}%"
  puts "=" * 60
end
