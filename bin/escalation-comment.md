<!-- The comment bin/dispatch-tick.sh posts when Dispatch's circuit breaker escalates an item. -->
<!-- It is posted straight to The Index, past every Claude-side prose check, so bin/test-dispatch-tick.sh runs tests/comms-check.py on it instead: on each comment a tick posts, and on a direct render of this file. -->
<!-- {{agent}} is the agent the breaker stopped, and {{budget_row}} its budget setting. -->
<!-- A {{reason}} line alone is replaced by the breaker's reason. -->
<!-- The budget block stays only when the reason is the USD budget cap. -->
<!-- Lines that are whole HTML comments, like these, are dropped. -->
Dispatch's circuit breaker stopped the {{agent}} runs on this item and moved it to Escalated.

The breaker gave this reason:

~~~text
{{reason}}
~~~

Without the breaker, Dispatch would start a new run on every tick, and each run would fail the same way. The breaker pulled the item from its lane to stop that loop.

To try again, move the item back to its lane. Dispatch then runs it one more time, with a raised budget.
<!-- budget -->

The runs stopped at the USD budget cap. Before you move the item back, raise the `{{budget_row}}` setting of workbench-dev-team in `/config`, or split the work into smaller items.
<!-- /budget -->
