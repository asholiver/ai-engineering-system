# Guard v2 decision policy. Applied after classification, as a separate step, so policy that
# needs more context (agent_type, authority store, delivery policy for deploy classes) is
# added here without touching the parser or the tables.
#
# Input: the result of parse_script ({units, uncertain}) and a context object.
# Output: {decision: "none" | "ask" | "deny", reason, classes, ops: [{operation, classes}]}.
# The guard never returns "allow".

def guardrail_note: "Hooks are guardrails, not a sandbox.";

def describe_op: .l + " [" + (.c | join(", ")) + "]";

def compound_policy($result):
  ([ $result.units[].ops[] ]) as $ops
  # A unit with no operation of its own that does real work (anything but context setup).
  | ([ $result.units[] | select((.ops | length) == 0 and .kind == "eff") ] | length) as $other_commands
  | if ($ops | length) == 0 then {decision: "none", reason: "", classes: [], ops: []}
    else
      ([ $ops[].c[] ] | unique) as $classes
      | ($ops | map({operation: .l, classes: .c})) as $summary
      | if ($ops | length) > 1 then
          {decision: "deny", classes: $classes, ops: $summary,
           reason: ("ai-engineering guard: denied. This command contains several reserved operations ("
                    + ($ops | map(describe_op) | join("; "))
                    + "). Resubmit each one on its own, as a separate Bash call, so a human approves one operation at a time. "
                    + guardrail_note)}
        elif $other_commands > 0 then
          {decision: "deny", classes: $classes, ops: $summary,
           reason: ("ai-engineering guard: denied. " + ($ops[0] | describe_op)
                    + " was submitted together with other commands. Resubmit " + $ops[0].l
                    + " on its own, as a separate Bash call, so a human can approve that single operation. "
                    + guardrail_note)}
        else
          {decision: "ask", classes: $classes, ops: $summary,
           reason: ("ai-engineering guard: this operation needs explicit human approval: " + ($ops[0] | describe_op) + ". " + guardrail_note)}
        end
    end;

def decide($result; $context):
  compound_policy($result);
