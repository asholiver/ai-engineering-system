#!/bin/bash
# Table-driven tests for the ai-engineering plugin scripts. Runs without network access
# and without Claude: each hook is fed the JSON input Claude Code would send it.
set -u
repository_directory="$(cd "$(dirname "$0")/.." && pwd)"
scripts="$repository_directory/plugins/ai-engineering/scripts"
work_directory="$(mktemp -d "${TMPDIR:-/tmp}/ai-engineering-tests.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT
export CLAUDE_PLUGIN_DATA="$work_directory/plugin-data"
export CLAUDE_PROJECT_DIR="$work_directory/no-project"

passed=0
failed=0
pass() { passed=$((passed + 1)); }
fail() { failed=$((failed + 1)); echo "FAIL: $1"; }
expect_equal() { if [ "$2" = "$3" ]; then pass; else fail "$1 (expected '$2', got '$3')"; fi; }
expect_contains() { case "$3" in *"$2"*) pass ;; *) fail "$1 (expected output containing '$2', got '$3')" ;; esac; }

new_repository() {
  local directory="$work_directory/$1" branch="$2"
  mkdir -p "$directory"
  git -C "$directory" init -q -b "$branch"
  git -C "$directory" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
  printf '%s\n' "$directory"
}

tool_input() { jq -n --arg command "$1" --arg cwd "$2" '{tool_input: {command: $command}, cwd: $cwd}'; }
decision_of() { jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null <<<"$1" | grep . || echo none; }

# ---------------------------------------------------------------- guard-bash
feature_repository="$(new_repository feature-repo feature)"
main_repository="$(new_repository main-repo main)"

while IFS='|' read -r expected command_text; do
  [ -n "$expected" ] || continue
  output="$(tool_input "$command_text" "$feature_repository" | "$scripts/guard-bash.sh")"
  expect_equal "guard-bash: $command_text" "$expected" "$(decision_of "$output")"
done <<'CASES'
ask|terraform apply
ask|terraform -chdir=infra apply -auto-approve
ask|tofu destroy
ask|terragrunt run-all apply
ask|FOO=1 terraform apply
ask|bash -c "terraform apply"
ask|pulumi up --yes
ask|npx cdk deploy MyStack
ask|cdk destroy
ask|kubectl delete pod web-1
ask|sudo kubectl -n prod delete deployment api
ask|helm uninstall api
ask|aws s3 rm s3://bucket/key
ask|aws s3 rb s3://bucket --force
ask|aws ec2 terminate-instances --instance-ids i-123
ask|aws s3 sync . s3://bucket --delete
ask|gcloud compute instances delete vm-1
ask|az group delete -n rg
ask|psql -c "DROP TABLE users"
ask|mysql -e "drop database app"
ask|psql -c "TRUNCATE orders"
ask|git push --force origin feature
ask|git push -f origin feature
ask|git push --force-with-lease origin feature
ask|git push origin +feature
ask|git push origin --delete feature
ask|git push origin :feature
ask|git push origin main
ask|git push origin HEAD:master
ask|git push --tags
ask|gh pr merge 12 --squash
ask|gh release create v1.0.0
ask|npm publish
ask|pnpm publish --access public
ask|yarn npm publish
ask|cargo publish
ask|twine upload dist/*
ask|docker push org/image:1
ask|npm run deploy:prod
ask|make deploy
ask|./scripts/release.sh
none|terraform plan
none|terraform plan -destroy
none|terraform init
none|pulumi preview
none|kubectl get pods
none|aws s3 ls
none|aws ec2 describe-instances
none|git push -u origin feature
none|git push origin feature
none|git status
none|git commit -m "update readme"
none|npm run build
none|npm test
none|ls -la
none|psql -c "select * from users"
none|gh pr create --draft
none|gh pr view 12
none|make test
none|docker build .
CASES

expect_equal "guard-bash: git push while on main" ask "$(decision_of "$(tool_input "git push" "$main_repository" | "$scripts/guard-bash.sh")")"
expect_equal "guard-bash: empty command" none "$(decision_of "$(jq -n '{tool_input: {}}' | "$scripts/guard-bash.sh")")"
reason="$(tool_input "terraform apply" "$feature_repository" | "$scripts/guard-bash.sh" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
expect_contains "guard-bash: reason states guardrail limits" "not a sandbox" "$reason"

# ---------------------------------------------------------------- guard-writes
write_input() { jq -n --arg agent "$1" --arg path "$2" --arg cwd "$3" '{agent_type: $agent, tool_input: {file_path: $path}, cwd: $cwd}' | sed 's/"agent_type": ""/"agent_type": null/'; }
mkdir -p "$feature_repository/.agents/learnings"
physical_repository="$(cd "$feature_repository" && pwd -P)"

while IFS='|' read -r expected agent target; do
  [ -n "$expected" ] || continue
  output="$(write_input "$agent" "$target" "$feature_repository" | "$scripts/guard-writes.sh")"
  expect_equal "guard-writes: $agent -> $target" "$expected" "$(decision_of "$output")"
done <<CASES
none|ai-engineering:learning|$feature_repository/.agents/learnings/cache-stampede.md
none|ai-engineering:learning|$physical_repository/.agents/regressions/new-folder/entry.md
none|ai-engineering:learning|.agents/learnings/relative.md
deny|ai-engineering:learning|$feature_repository/src/app.ts
deny|ai-engineering:learning|$feature_repository/.agents/../src/app.ts
deny|ai-engineering:learning|$feature_repository/AGENTS.md
deny|ai-engineering:learning|$work_directory/outside.md
none|ai-engineering:backend|$feature_repository/src/app.ts
none||$feature_repository/src/app.ts
CASES

# ---------------------------------------------------------------- run-gate
commit_all() { git -C "$1" add -A && git -C "$1" -c user.name=test -c user.email=test@example.com commit -q -m "$2"; }
gate_repository="$(new_repository gate-repo main)"
mkdir -p "$gate_repository/.agents"
printf '%s\n' 'pass-marker' >"$gate_repository/.gitignore"
cat >"$gate_repository/.agents/gates.json" <<'JSON'
{ "fast": "test -f pass-marker", "full": "for line in $(seq 1 20); do echo line-$line; done; exit 2", "externalReview": null }
JSON

output="$("$scripts/run-gate.sh" fast "$gate_repository")"; exit_code=$?
expect_equal "run-gate: failing gate exit code" 1 "$exit_code"
expect_contains "run-gate: failing verdict" "GATE fast: FAILED (exit 1)" "$output"
expect_contains "run-gate: uncommitted gates are flagged" "using uncommitted .agents/gates.json" "$output"
commit_all "$gate_repository" gates

jq '.fast = "true"' "$gate_repository/.agents/gates.json" >"$work_directory/tampered.json"
cp "$work_directory/tampered.json" "$gate_repository/.agents/gates.json"
output="$("$scripts/run-gate.sh" fast "$gate_repository")"; exit_code=$?
expect_equal "run-gate: uncommitted edit cannot weaken a committed gate" 1 "$exit_code"
expect_contains "run-gate: ignored edit is reported" "uncommitted changes to .agents/gates.json were ignored" "$output"
git -C "$gate_repository" checkout -q -- .agents/gates.json

output="$(GATE_OUTPUT_LINES=5 "$scripts/run-gate.sh" full "$gate_repository")"; exit_code=$?
expect_equal "run-gate: full gate exit code" 1 "$exit_code"
expect_contains "run-gate: output is bounded" "15 earlier lines omitted" "$output"
touch "$gate_repository/pass-marker"
output="$("$scripts/run-gate.sh" fast "$gate_repository/")"; exit_code=$?
expect_equal "run-gate: passing gate exit code" 0 "$exit_code"
case "$output" in *NOTE*) fail "run-gate: clean committed gates should not print a note" ;; *) pass ;; esac
output="$("$scripts/run-gate.sh" missing "$gate_repository")"; exit_code=$?
expect_equal "run-gate: unconfigured gate exit code" 3 "$exit_code"
expect_contains "run-gate: unconfigured verdict" "NOT CONFIGURED" "$output"
rm "$gate_repository/pass-marker"

risky_repository="$(new_repository risky-repo feature)"
mkdir -p "$risky_repository/.agents"
printf '%s\n' '{ "fast": "npm test && terraform apply -auto-approve" }' >"$risky_repository/.agents/gates.json"
output="$("$scripts/run-gate.sh" fast "$risky_repository")"; exit_code=$?
expect_equal "run-gate: high-impact gate command is refused" 5 "$exit_code"
expect_contains "run-gate: refusal verdict" "GATE fast: REFUSED" "$output"

# ---------------------------------------------------------------- gate-fast (SubagentStop)
stop_input() { jq -n --arg id "$1" --arg cwd "$2" '{hook_event_name: "SubagentStop", agent_id: $id, agent_type: "ai-engineering:backend", cwd: $cwd}'; }
run_stop_hook() { stop_input "$1" "$2" | "$scripts/gate-fast.sh" 2>"$work_directory/stderr"; }

stdout="$(run_stop_hook agent-a "$gate_repository")"; exit_code=$?
expect_equal "gate-fast: first failure blocks" 2 "$exit_code"
expect_contains "gate-fast: first failure message" "fix attempt 1 of 2" "$(cat "$work_directory/stderr")"
run_stop_hook agent-a "$gate_repository" >/dev/null; exit_code=$?
expect_equal "gate-fast: second failure blocks" 2 "$exit_code"
expect_contains "gate-fast: second failure message" "fix attempt 2 of 2" "$(cat "$work_directory/stderr")"
run_stop_hook agent-a "$gate_repository" >/dev/null; exit_code=$?
expect_equal "gate-fast: third failure blocks for escalation" 2 "$exit_code"
expect_contains "gate-fast: escalation instruction" "GATE FAILED" "$(cat "$work_directory/stderr")"
stdout="$(run_stop_hook agent-a "$gate_repository")"; exit_code=$?
expect_equal "gate-fast: stops after escalation" 0 "$exit_code"
expect_contains "gate-fast: escalation message to user" "escalation reported" "$stdout"

touch "$gate_repository/pass-marker"
run_stop_hook agent-b "$gate_repository" >/dev/null; exit_code=$?
expect_equal "gate-fast: passing gate lets agent stop" 0 "$exit_code"
rm "$gate_repository/pass-marker"

echo "garbage" >"$CLAUDE_PLUGIN_DATA/gate-attempts/agent-e"
run_stop_hook agent-e "$gate_repository" >/dev/null; exit_code=$?
expect_equal "gate-fast: corrupt attempt counter restarts at the first attempt" 2 "$exit_code"
expect_contains "gate-fast: corrupt counter message" "fix attempt 1 of 2" "$(cat "$work_directory/stderr")"

git -C "$gate_repository" worktree add -q "$work_directory/gate-worktree" -b worktree-branch
touch "$work_directory/gate-worktree/pass-marker"
mkdir -p "$work_directory/gate-worktree/src"
run_stop_hook agent-c "$work_directory/gate-worktree/src" >/dev/null; exit_code=$?
expect_equal "gate-fast: runs in the agent's worktree root" 0 "$exit_code"

unconfigured_repository="$(new_repository unconfigured-repo feature)"
stdout="$(run_stop_hook agent-d "$unconfigured_repository")"; exit_code=$?
expect_equal "gate-fast: unconfigured gate lets agent stop" 0 "$exit_code"
expect_contains "gate-fast: unconfigured gate is reported" "NOT CONFIGURED" "$stdout"

stdout="$(run_stop_hook agent-f "$risky_repository")"; exit_code=$?
expect_equal "gate-fast: refused gate lets agent stop" 0 "$exit_code"
expect_contains "gate-fast: refused gate is reported" "REFUSED" "$(jq -r .systemMessage <<<"$stdout")"

# ---------------------------------------------------------------- external-review
review_repository="$(new_repository review-repo main)"
mkdir -p "$review_repository/.agents"
set_review_command() { jq -n --arg command "$1" '{externalReview: (if $command == "" then null else $command end)}' >"$review_repository/.agents/gates.json"; }
run_review() { (cd "$1" && "$scripts/external-review.sh" main HEAD .agents/specs/active/WORK-1.md); }

set_review_command ""
commit_all "$review_repository" "null reviewer"
output="$(run_review "$review_repository")"; exit_code=$?
expect_equal "external-review: null command exit code" 3 "$exit_code"
expect_contains "external-review: null command verdict" "EXTERNAL REVIEW: NOT CONFIGURED" "$output"

set_review_command "exit 0"
output="$(run_review "$review_repository")"; exit_code=$?
expect_equal "external-review: uncommitted reviewer command is ignored" 3 "$exit_code"
git -C "$review_repository" checkout -q -- .agents/gates.json

output="$(run_review "$unconfigured_repository")"; exit_code=$?
expect_equal "external-review: missing gates file exit code" 3 "$exit_code"

while IFS='|' read -r reviewer_exit expected_exit expected_verdict; do
  [ -n "$reviewer_exit" ] || continue
  set_review_command "echo \"reviewing \$REVIEW_BASE_REF..\$REVIEW_HEAD_REF for \$REVIEW_SPEC_PATH\"; exit $reviewer_exit"
  commit_all "$review_repository" "reviewer exit $reviewer_exit"
  output="$(run_review "$review_repository")"; exit_code=$?
  expect_equal "external-review: reviewer exit $reviewer_exit" "$expected_exit" "$exit_code"
  expect_contains "external-review: reviewer exit $reviewer_exit verdict" "$expected_verdict" "$output"
  expect_contains "external-review: contract environment" "reviewing main..HEAD for .agents/specs/active/WORK-1.md" "$output"
done <<'CASES'
0|0|EXTERNAL REVIEW: PASSED
7|2|EXTERNAL REVIEW: ERROR (reviewer exit 7)
1|1|EXTERNAL REVIEW: BLOCKING FINDINGS
CASES

git -C "$review_repository" checkout -q -b change-under-review
set_review_command "exit 0"
commit_all "$review_repository" "change tries to replace its reviewer"
output="$(run_review "$review_repository")"; exit_code=$?
expect_equal "external-review: a change cannot replace its own reviewer" 1 "$exit_code"
expect_contains "external-review: replaced reviewer is reported" "this change modifies externalReview" "$output"

git -C "$review_repository" checkout -q main
set_review_command "terraform apply -auto-approve"
commit_all "$review_repository" "high-impact reviewer"
output="$(run_review "$review_repository")"; exit_code=$?
expect_equal "external-review: high-impact reviewer command is refused" 2 "$exit_code"
expect_contains "external-review: refusal verdict" "refused" "$output"

# ---------------------------------------------------------------- inject-standards
output="$(CLAUDE_PLUGIN_ROOT="$repository_directory/plugins/ai-engineering" "$scripts/inject-standards.sh")"
expect_contains "inject-standards: includes standards body" "# Engineering Standards" "$output"
case "$output" in *"user-invocable"*) fail "inject-standards: frontmatter leaked into context" ;; *) pass ;; esac

echo "tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
