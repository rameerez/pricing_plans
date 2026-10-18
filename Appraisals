# frozen_string_literal: true

appraise "rails-7.1" do
  gem "rails", "~> 7.1.0"
  # Rails 7.1 passes quirks_mode: to JSON.generate; json >= 3 rejects unknown keywords.
  gem "json", "~> 2.7"
end

appraise "rails-7.2" do
  gem "rails", "~> 7.2.3", ">= 7.2.3.2"
end

appraise "rails-8.1" do
  gem "rails", "~> 8.1.2"
end
