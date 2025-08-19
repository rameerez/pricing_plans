
# Controller helpers and methods

The `pricing_plans` gem ships with controller helpers that make it easy to gate features defined in your pricing plans, and enforce limits. For these controllers methods to work, you first need to let the gem know who the current "plan owner" object is. The plan owner is the object on which the plan limits are applied (typically, the same object that gets billed for a subscription: the current user, current organization, etc.)

## Setting things up for controllers

First of all, the gem needs a way to know what the current plan owner object is (the current user, current organization, etc.)

You can set this globally in the initializer:
```ruby
# config/initializers/pricing_plans.rb
PricingPlans.configure do |config|
  # Either:
  config.controller_plan_owner :current_organization
  # Or:
  # config.controller_plan_owner { current_account }
end
```

If this is not defined, `pricing_plans` will [auto-try common conventions](/lib/pricing_plans/controller_guards.rb):
- `current_organization`
- `current_account`
- `current_user`
- `current_team`
- `current_company`
- `current_workspace`
- `current_tenant`
- If you set `plan_owner_class` in `pricing_plans.rb`, we’ll also try `current_<plan_owner_class>`.

If these methods are already defined in your Application Controller or individual controller(s), there's nothing you need to do! For example: `pricing_plans` works out of the box with Devise, because Devise already defines `current_user` at the Application Controller level.

If none of those methods are defined, or if you want custom logic, we recommend defining / overriding the method in your `ApplicationController`:
```ruby
class ApplicationController < ActionController::Base
  # Adapt to your auth/session logic
  def current_organization
    # Your lookup here (e.g., current_user.organization)
  end
end
```

If needed, you can override the plan owner per controller:
```ruby
class YourSpecificController < ApplicationController
  pricing_plans_plan_owner :current_organization

  # Or pass a block:
  # pricing_plans_plan_owner { current_user&.organization }
end
```

Once all of this is configured, you can gate features and enforce limits easily in your controllers.

## Gate features in controllers

Feature-gate any controller action with:

```ruby
before_action { gate_feature!(:api_access) }
```

You can also specify the plan owner to override global or per-controller settings:

```ruby
before_action { gate_feature!(:api_access, plan_owner: current_organization) }
```

We also provide syntactic sugar for each feature defined in your pricing plans. For example, if you defined `allows :api_access` in your plans, you can simply enforce it like this instead:

```ruby
before_action :enforce_api_access!
```

You can use it along with any other controller filters too:

```ruby
before_action :enforce_api_access!, only: [:create]
```

These `enforce_<feature_key>!` controller helper methods are dynamically generated for each of the features `<feature_key>` you defined in your plans. So, for the helper above to work, you would have to have defined a plan with `allows :api_access` in your `pricing_plans.rb` file.

When the feature is disallowed, the controller will raise a `FeatureDenied` (we rescue it by default). You can customize the response by overriding `handle_pricing_plans_feature_denied(error)` in your `ApplicationController`:

```ruby
class ApplicationController < ActionController::Base
  private

  # Override the default 403 handler (optional)
  def handle_pricing_plans_feature_denied(error)
    # Custom HTML handling
    redirect_to upgrade_path, alert: error.message, status: :see_other
  end
end
```

## Enforce plan limits in controllers

You can enforce limits for any action:

```ruby
before_action { enforce_plan_limit!(:projects) }
```

You can also override who the plan owner is:

```ruby
before_action { enforce_plan_limit!(:projects, plan_owner: current_organization) }
```

As with feature gating, there is syntactic sugar per limit:

```ruby
before_action :enforce_projects_limit!
```

The pattern is `enforce_<limit_key>_limit!` -- a method gets generated for every different `<limit_key>` defined with the `limits` keyword in `pricing_plans.rb`.


You can also specify a custom redirect path that will override the global config:
```ruby
before_action { enforce_plan_limit!(:projects, plan_owner: current_organization, redirect_to: pricing_path) }
```

> [!IMPORTANT]
> Enforcing a plan limit means "checking if **one more** object can be created". That is the default behavior. If you need to check whether you are at distance 2, or distance _n_ from the limit, you can pass the `by` argument as described below.

In the example aboves, the gem assumes the action to call will only create one extra project. So, if the plan limit is 5, and you're currently at 4 projects, you can still create one extra one, and the action will get called. If your action creates more than one object per call (creating multiple objects at once, importing objects in bulk etc.) you can enforce it will stay within plan limits by passing the `by:` parameter like this:

```ruby
before_action { enforce_projects_limit!(by: 10) }  # Checks whether current_organization can create 10 more projects within its plan limits
```

### Getting the raw `result` from a limit check

The `require_plan_limit!` method is also available (`require_`, not `enforce_`). This method returns a raw `result` object which is the result of checking the limit with respect to the current plan owner. You can call these on `result`:
- `result.message`
- `result.ok?`
- `result.warning?`
- `result.grace?`
- `result.blocked?`
- `result.success?`

This is useful for checking and enforcing limits mid-action (rather than via a `before_action` hook):

```ruby
def create
  result = require_plan_limit!(:products, plan_owner: current_organization, by: 1)

  if result.blocked? # ok?, warning?, grace?, blocked?, success?
    # result.message is available:
    redirect_to pricing_path, alert: result.message, status: :see_other and return
  end

  # ...
  Product.create!(...)
  redirect_to products_path
end
```

You can also define how your application responds when a limit check blocks an action by defining `handle_pricing_plans_limit_blocked` in your controller:

```ruby
class ApplicationController < ActionController::Base
  private

  def handle_pricing_plans_limit_blocked(result)
    # Default behavior (HTML): flash + redirect_to(pricing_path) if defined; else render 403
    # You can customize globally here. The Result carries rich context:
    # - result.limit_key, result.plan_owner, result.message, result.metadata
    redirect_to(pricing_path, status: :see_other, alert: result.message)
  end
end
```

`enforce_plan_limit!` invokes this handler when `result.blocked?`, passing a `Result` enriched with `metadata[:redirect_to]` resolved via:
  1. explicit `redirect_to:` option
  2. per-controller default `self.pricing_plans_redirect_on_blocked_limit`
  3. global `config.redirect_on_blocked_limit`
  4. `pricing_path` helper if available


## Set up a redirect when a limit is reached

You can optionally configure a global default redirect:

```ruby
# config/initializers/pricing_plans.rb
PricingPlans.configure do |config|
  config.redirect_on_blocked_limit = :pricing_path # or "/pricing" or ->(result) { pricing_path }
end
```

Or a per-controller default (optional):

```ruby
class ApplicationController < ActionController::Base
  self.pricing_plans_redirect_on_blocked_limit = :pricing_path
end
```

Redirect resolution priority:
1) `redirect_to:` option on the call
2) Per-controller `self.pricing_plans_redirect_on_blocked_limit`
3) Global `config.redirect_on_blocked_limit`
4) `pricing_path` helper (if present)
5) Fallback: render 403 (HTML or JSON)

Per-controller default accepts:
- Symbol: helper method name (e.g., `:pricing_path`)
- String: path or URL (e.g., `"/pricing"`)
- Proc: `->(result) { pricing_path }` (instance-exec'd in the controller)

Global default accepts the same types. The Proc receives the `Result` so you can branch on `limit_key`, etc.

Recommended patterns:
- Set a single global default in your initializer.
- Override per controller only if UX differs for a section.
- Use the dynamic helpers as symbols in before_action for clarity:
```ruby
before_action :enforce_projects_limit!, only: :create
before_action :enforce_api_access!
```
