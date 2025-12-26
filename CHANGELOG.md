# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2025-12-26

- Fix a bug in the pay gem integration that would always return the default pricing plan regardless of the actual Pay subscription
- Add hidden plans, enabling grandfathering, no-free-users use cases, etc.
- Prevent unlimited limits for limits that were undefined

## [0.1.1] - 2025-12-25

- Add support for Rails 8+
- Fix a bug where `throw :abort` was causing `UncaughtThrowError` exceptions in controller guards, and instead return `false` from `before_action` callbacks to halt the filter chain, rather than using the uncaught throw

## [0.1.0] - 2025-08-19

Initial release