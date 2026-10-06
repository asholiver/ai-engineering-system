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
unset AI_ENGINEERING_HOOK_GATES

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

# ---- guard-bash v2: parse, then classify. Table cases are "expected|command"; "\n" in a
# command is a newline. Existing v0.2 cases above are unchanged and all still pass: none of
# their expectations changed. Compound commands that now deny are listed under "deny".
guard_decision() { decision_of "$(tool_input "${1//\\n/$'\n'}" "${2:-$feature_repository}" | "$scripts/guard-bash.sh")"; }
guard_reason() { tool_input "${1//\\n/$'\n'}" "${2:-$feature_repository}" | "$scripts/guard-bash.sh" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

while IFS='|' read -r expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "guard-bash v2: $command_text" "$expected" "$(guard_decision "$command_text")"
done <<'CASES'
none|python3 - <<'EOF'\nsource = source.replace("pnpm audit", "x"); a = "vercel deploy --prebuilt"; b = "production deploy"; c = "release"\nEOF
none|nvm use && "$PLUGIN/scripts/run-gate.sh" fast && git status --short && grep -rn "DROP\|TRUNCATE" --include=*.ts src app scripts tests
none|python3 -c "open('f.ts','w').write('in-memory limit is per-instance on serverless platforms; remove the entry')"
none|sed -i 's/a/in-memory limit is per-instance on serverless platforms; remove the entry/' f.ts
none|curl -fsSLO https://github.com/org/tool/releases/download/v8.30.1/checksums.txt
none|for tag in v1 v2; do curl -s https://api.github.com/repos/o/r/releases/latest | jq .tag_name; done
none|gh release download v1.2.3 -p checksums.txt
none|gh release view v1.2.3
none|gh release list
none|gh api repos/o/r/releases/latest
none|rg -n 'terraform apply' docs/
none|git log -S 'TRUNCATE'
none|git grep "npm publish"
none|cat > notes.md <<'EOF'\nProse about terraform destroy and git push --force.\nEOF
none|git commit -m "docs: explain how to deploy and release"
none|echo "run npm publish later"
none|curl https://api.github.com/repos/o/r/releases
none|curl -X POST https://example.com/api/items
none|wget -qO- https://example.com/releases/latest
none|command -v terraform
none|terraform plan && terraform validate
none|ls # terraform apply
none|printf 'x' | wc -c
none|pnpm add release-it
none|git add scripts/release.sh
none|cat ./scripts/deploy.sh
none|python3 -c "print('truncate the string to 10 chars')"
none|sudo -u root ls
none|echo hi | tee out.log
ask|psql "$URL" -c "DROP DATABASE landra_test"
ask|echo "TRUNCATE t" | psql
ask|psql <<'SQL'\nDROP TABLE x;\nSQL
ask|bash -c 'npm publish'
ask|pnpm run deploy
ask|pnpm release
ask|serverless remove --stage prod
ask|npx serverless remove
ask|sls remove
ask|sam delete --stack-name x
ask|gh release create v1.2.3
ask|gh release delete v1.2.3
ask|curl -X POST https://api.github.com/repos/o/r/releases
ask|curl -d '{}' https://api.github.com/repos/o/r/releases
ask|curl -X DELETE https://api.github.com/repos/o/r/git/refs/heads/x
ask|wget --post-data=x https://api.github.com/repos/o/r/releases
ask|gh api -X POST repos/o/r/releases
ask|gh api -X PUT repos/o/r/pulls/3/merge
ask|gh api -f tag_name=v1 repos/o/r/releases
ask|gh api -X DELETE repos/o/r/git/refs/heads/x
ask|vercel --prod
ask|vercel deploy
ask|vercel promote https://x.vercel.app
ask|netlify deploy --prod
ask|cd infra && terraform apply
ask|node -e "await sql`DROP DATABASE x`"
ask|git push --tags
ask|./scripts/release.sh
ask|bash scripts/deploy.sh
ask|export A=1 && terraform apply
ask|cd x && source .venv/bin/activate && terraform apply
ask|corepack enable && pnpm publish
ask|nvm use 20 && npm publish
ask|terraform apply 2>&1 | tail -5
ask|terraform apply > out.log
ask|kubectl --context prod delete pod x
ask|kubectl get pods | xargs -I{} kubectl delete pod {}
ask|echo $(terraform apply)
ask|if true; then terraform apply; fi
ask|FOO=1 sudo -u root terraform apply
ask|time nice -n 5 terraform destroy
ask|env FOO=1 terraform apply
ask|pnpm exec vercel --prod
ask|bunx vercel --prod
ask|npx -y vercel remove x
ask|ssh host 'kubectl delete pod x'
ask|eval "terraform apply"
ask|bash <<'EOF'\nterraform apply\nEOF
ask|echo "terraform apply" | sh
ask|cat <<EOF\n$(terraform apply)\nEOF
ask|python3 - <<'EOF'\ncur.execute("DROP TABLE users")\nEOF
ask|neonctl branches delete br-1
ask|neon projects delete p-1
ask|vercel env rm FOO
ask|vercel project rm p
ask|vercel domains rm example.com
ask|vercel remove my-deploy
ask|vercel rm my-deploy
ask|make release
ask|serverless deploy
ask|cdk deploy MyStack
ask|te''rraform apply
ask|\terraform apply
ask|command terraform apply
ask|/usr/local/bin/terraform apply
ask|"git" push --force origin feature
ask|git -C repo push -f
ask|git -c x=y push origin main
ask|$(echo terraform) apply
ask|`which kubectl` delete pod x
ask|cd x\nterraform apply
ask|xargs -I{} kubectl delete pod {}
deny|psql -c "DROP DATABASE x" && pnpm test
deny|pnpm test && git push --force origin feature
deny|npm run build; npm publish
deny|git status && gh pr merge 12 --squash
deny|terraform apply && kubectl delete pod x
deny|for f in a b; do terraform apply; done
deny|echo start\nterraform apply\necho done
deny|bash -c 'npm run build; npm publish'
CASES

# Fail-safe: unparseable commands fall back to the v0.2 keyword rules, which ask and never deny.
while IFS='|' read -r expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "guard-bash fail-safe: $command_text" "$expected" "$(guard_decision "$command_text")"
done <<'CASES'
ask|echo "unbalanced; terraform apply
ask|psql -c "DROP TABLE x && pnpm test "
ask|echo 'oops; git push --force origin feature
ask|echo $(terraform apply
ask|$CMD apply && terraform apply
none|echo "unbalanced and harmless
none|$CMD apply
CASES

# Classes: the class labels, in particular the deploy classes, all still ask.
while IFS='|' read -r expected_class command_text; do
  [ -n "$expected_class" ] || continue
  output="$(tool_input "$command_text" "$feature_repository" | "$scripts/guard-bash.sh")"
  expect_equal "guard-bash class decision: $command_text" ask "$(decision_of "$output")"
  expect_contains "guard-bash class: $command_text" "[$expected_class" "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
done <<'CASES'
production-deploy|vercel --prod
production-deploy|vercel deploy --prod
production-deploy|vercel promote https://x.vercel.app
production-deploy|netlify deploy --prod
ephemeral-deploy|vercel
ephemeral-deploy|vercel deploy
ephemeral-deploy|netlify deploy
unclassified-deploy|pnpm run deploy
unclassified-deploy|./scripts/release.sh
unclassified-deploy|make release
platform-destructive|neonctl branches delete br-1
platform-destructive|neonctl projects delete p-1
platform-destructive|neonctl databases delete d
platform-destructive|neonctl roles delete r
platform-destructive|vercel remove x
platform-destructive|vercel rm x
platform-destructive|vercel env rm F
platform-destructive|vercel project rm p
platform-destructive|vercel domains rm d
infrastructure-apply|tofu destroy
kubernetes-delete|helm uninstall api
cloud-destructive|aws s3 rb s3://bucket
destructive-sql|psql -c "TRUNCATE orders"
git-force-push|git push -f origin feature
git-main-push|git push origin main
git-tag-push|git push --tags
pr-merge|gh pr merge 12
release-create|gh release create v1
package-publish|npm publish
image-publish|docker push org/image:1
CASES

# Reason wording. Deny: names the operation and says to resubmit it alone. Ask: names the
# single operation and its class, and keeps the guardrail note.
reason="$(guard_reason 'pnpm test && git push --force origin feature')"
expect_contains "guard-bash: deny names the operation" "git push (force or delete)" "$reason"
expect_contains "guard-bash: deny says to resubmit alone" "Resubmit git push (force or delete) on its own" "$reason"
expect_equal "guard-bash: deny decision" deny "$(guard_decision 'pnpm test && git push --force origin feature')"
reason="$(guard_reason 'cd infra && terraform apply')"
expect_contains "guard-bash: ask names the operation" "terraform apply" "$reason"
expect_contains "guard-bash: ask names the class" "infrastructure-apply" "$reason"
expect_contains "guard-bash: ask keeps the guardrail note" "Hooks are guardrails, not a sandbox." "$reason"
reason="$(guard_reason 'terraform apply && kubectl delete pod x')"
expect_contains "guard-bash: several operations are each named" "kubectl delete" "$reason"
expect_contains "guard-bash: several operations resubmit alone" "on its own" "$reason"
reason="$(guard_reason 'echo "oops; terraform apply')"
expect_contains "guard-bash: fallback ask keeps the guardrail note" "Hooks are guardrails, not a sandbox." "$reason"
case "$(tool_input 'terraform apply' "$feature_repository" | "$scripts/guard-bash.sh")" in *'"allow"'*) fail "guard-bash: must never allow" ;; *) pass ;; esac

# Fail-safe: a missing jq asks. The guard runs with a PATH that has no jq.
empty_path="$work_directory/empty-path"
mkdir -p "$empty_path"
output="$(tool_input 'ls' "$feature_repository" | PATH="$empty_path" /bin/bash "$scripts/guard-bash.sh")"
expect_equal "guard-bash fail-safe: missing jq asks" ask "$(decision_of "$output")"

# Fail-safe: a command over the parser budget falls back to keywords and asks.
oversized_file="$work_directory/oversized.txt"
{ i=0; while [ "$i" -lt 6000 ]; do printf 'echo filler line number %s of the oversized command text here\n' "$i"; i=$((i + 1)); done; printf 'npm publish\n'; } >"$oversized_file"
jq -n --rawfile command "$oversized_file" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/oversized.json"
output="$("$scripts/guard-bash.sh" <"$work_directory/oversized.json")"
expect_equal "guard-bash fail-safe: oversized command with a reserved keyword asks" ask "$(decision_of "$output")"
sed 's/^npm publish$/npm test/' "$oversized_file" >"$work_directory/oversized-harmless.txt"
jq -n --rawfile command "$work_directory/oversized-harmless.txt" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/oversized-harmless.json"
expect_equal "guard-bash fail-safe: oversized harmless command is not denied" none "$(decision_of "$("$scripts/guard-bash.sh" <"$work_directory/oversized-harmless.json")")"

# Guard log: one line per ask or deny, never the command text; nothing for no decision.
log_repository="$(new_repository log-repo feature)"
log_file="$log_repository/.git/ai-engineering/guard-log.jsonl"
log_input() { jq -n --arg command "$1" --arg cwd "$log_repository" --arg agent "${2:-}" '{tool_input: {command: $command}, cwd: $cwd, session_id: "session-1", agent_type: (if $agent == "" then null else $agent end)}'; }
log_input 'git status' | "$scripts/guard-bash.sh" >/dev/null
if [ -e "$log_file" ]; then fail "guard log: a no-decision command wrote a line"; else pass; fi
log_input 'cd infra && terraform apply -var token=SECRET-VALUE-123' ai-engineering:backend | "$scripts/guard-bash.sh" >/dev/null
expect_equal "guard log: an ask writes one line" 1 "$(wc -l <"$log_file" | tr -d ' ')"
log_line="$(cat "$log_file")"
expect_equal "guard log: decision" ask "$(jq -r .decision <<<"$log_line")"
expect_equal "guard log: session id" session-1 "$(jq -r .sessionId <<<"$log_line")"
expect_equal "guard log: agent type" ai-engineering:backend "$(jq -r .agentType <<<"$log_line")"
expect_equal "guard log: classes" infrastructure-apply "$(jq -r '.classes | join(",")' <<<"$log_line")"
expect_equal "guard log: parse mode" parsed "$(jq -r .parseMode <<<"$log_line")"
expect_equal "guard log: time is an ISO timestamp" 1 "$(jq -r '.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$") | if . then 1 else 0 end' <<<"$log_line")"
expected_digest="$(printf '%s' 'cd infra && terraform apply -var token=SECRET-VALUE-123' | shasum -a 256 | cut -d' ' -f1)"
expect_equal "guard log: SHA-256 of the command" "$expected_digest" "$(jq -r .commandSha256 <<<"$log_line")"
case "$log_line" in *"terraform apply"* | *SECRET* | *"cd infra"*) fail "guard log: command text leaked into the log" ;; *) pass ;; esac
log_input 'pnpm test && git push --force origin feature' | "$scripts/guard-bash.sh" >/dev/null
expect_equal "guard log: a deny writes a line" deny "$(tail -n 1 "$log_file" | jq -r .decision)"
log_input 'echo "unbalanced; terraform apply' | "$scripts/guard-bash.sh" >/dev/null
expect_equal "guard log: fallback is recorded" fallback "$(tail -n 1 "$log_file" | jq -r .parseMode)"
expect_equal "guard log: three decisions, three lines" 3 "$(wc -l <"$log_file" | tr -d ' ')"
# Bounded size: past the cap the log rotates.
head -c 1100000 /dev/zero | tr '\0' 'x' >"$log_file"
log_input 'cd infra && terraform apply' | "$scripts/guard-bash.sh" >/dev/null
if [ -e "$log_file.1" ] && [ "$(wc -c <"$log_file" | tr -d ' ')" -lt 1000 ]; then pass; else fail "guard log: oversized log was not rotated"; fi
# A logging failure never changes the decision: the log directory cannot be created.
blocked_repository="$(new_repository blocked-log-repo feature)"
printf 'not a directory\n' >"$blocked_repository/.git/ai-engineering"
output="$(tool_input 'cd infra && terraform apply' "$blocked_repository" | "$scripts/guard-bash.sh")"
expect_equal "guard log: unwritable log directory still asks" ask "$(decision_of "$output")"
output="$(tool_input 'pnpm test && git push --force origin feature' "$blocked_repository" | "$scripts/guard-bash.sh")"
expect_equal "guard log: unwritable log directory still denies" deny "$(decision_of "$output")"

# Performance: generous bounds for CI machines (design target: p95 under 150 ms up to 8 KB,
# under 1 s up to 256 KB).
elapsed_milliseconds() {
  local seconds
  TIMEFORMAT=%3R
  seconds="$( { time "$scripts/guard-bash.sh" <"$1" >/dev/null; } 2>&1 )"
  echo $((10#${seconds/./}))
}
heredoc_file="$work_directory/heredoc.txt"
{ printf "python3 - <<'EOF'\n"; i=0; while [ "$i" -lt 3000 ]; do printf 'text with "quotes", it'"'"'s a note about pnpm audit and release; line %s of the body\n' "$i"; i=$((i + 1)); done; printf 'EOF\n'; } >"$heredoc_file"
jq -n --rawfile command "$heredoc_file" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/heredoc.json"
heredoc_bytes="$(wc -c <"$heredoc_file" | tr -d ' ')"
if [ "$heredoc_bytes" -gt 200000 ] && [ "$heredoc_bytes" -lt 262144 ]; then pass; else fail "performance: heredoc fixture is $heredoc_bytes bytes"; fi
expect_equal "performance: large heredoc is data, no decision" none "$(decision_of "$("$scripts/guard-bash.sh" <"$work_directory/heredoc.json")")"
heredoc_ms="$(elapsed_milliseconds "$work_directory/heredoc.json")"
if [ "$heredoc_ms" -lt 2500 ]; then pass; else fail "performance: ${heredoc_bytes}-byte heredoc took ${heredoc_ms} ms (budget 1000 ms, tolerance 2500 ms)"; fi
{ i=0; while [ "$i" -lt 60 ]; do printf 'grep -rn "foo\\|bar" --include=*.ts src/app%s | head -5 && ' "$i"; i=$((i + 1)); done; printf 'echo done'; } >"$work_directory/command-8k.txt"
jq -n --rawfile command "$work_directory/command-8k.txt" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/command-8k.json"
medium_ms="$(elapsed_milliseconds "$work_directory/command-8k.json")"
if [ "$medium_ms" -lt 500 ]; then pass; else fail "performance: 8 KB command took ${medium_ms} ms (budget 150 ms, tolerance 500 ms)"; fi
# A pathological command is cut off by the time budget or the fallback and still decides safely.
pathological_file="$work_directory/pathological.txt"
{ i=0; while [ "$i" -lt 3000 ]; do printf '$(('; i=$((i + 1)); done; printf 'terraform apply'; } >"$pathological_file"
jq -n --rawfile command "$pathological_file" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/pathological.json"
expect_equal "guard-bash fail-safe: pathological nesting asks" ask "$(decision_of "$("$scripts/guard-bash.sh" <"$work_directory/pathological.json")")"

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

# WORK-001 T3: lib.sh classification interface. Both ask and deny are high-impact; classes are
# exposed; classification never writes a guard-log entry that could pass for a hook decision.
(
  source "$scripts/lib.sh"
  classify_command_impact "terraform apply" "$risky_repository"; status=$?
  [ "$status" -eq 0 ] && [ "$impact_decision" = "ask" ] && [ "$impact_classes" = "infrastructure-apply" ] || exit 1
  classify_command_impact "npm test && terraform apply -auto-approve" "$risky_repository"; status=$?
  [ "$status" -eq 0 ] && [ "$impact_decision" = "deny" ] && [ "$impact_classes" = "infrastructure-apply" ] || exit 2
  classify_command_impact "git status" "$risky_repository"; status=$?
  [ "$status" -ne 0 ] && [ "$impact_decision" = "none" ] && [ -z "$impact_classes" ] || exit 3
  is_high_impact_command "npm test && terraform apply" "$risky_repository" || exit 4
  # Parse failure (unbalanced quote) with a reserved keyword takes the keyword fallback: still high-impact.
  classify_command_impact "echo 'unbalanced; terraform apply" "$risky_repository" || exit 5
  [ "$impact_decision" = "ask" ] || exit 6
)
expect_equal "lib: classify_command_impact decision and classes (exit code identifies the failed check)" 0 "$?"
if [ -e "$risky_repository/.git/ai-engineering/guard-log.jsonl" ]; then fail "lib: classification wrote a guard-log entry"; else pass; fi

# Regression: classify-only is selected by an argument only. An environment variable (settable
# through a committed settings env block) must never change the hook's output or logging.
for bypass_variable in AI_ENGINEERING_GUARD_CLASSIFY_ONLY AI_ENGINEERING_GUARD_CLASSIFY; do
  rm -f "$risky_repository/.git/ai-engineering/guard-log.jsonl"
  lone_input="$(jq -n --arg command "terraform apply" --arg cwd "$risky_repository" '{tool_input: {command: $command}, cwd: $cwd}')"
  compound_input="$(jq -n --arg command "npm test && terraform apply" --arg cwd "$risky_repository" '{tool_input: {command: $command}, cwd: $cwd}')"
  output="$(env "$bypass_variable=1" "$scripts/guard-bash.sh" <<<"$lone_input")"
  expect_equal "guard: $bypass_variable=1 cannot turn a lone reserved command into a non-decision" ask "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output" 2>/dev/null)"
  output="$(env "$bypass_variable=1" "$scripts/guard-bash.sh" <<<"$compound_input")"
  expect_equal "guard: $bypass_variable=1 cannot turn a compound reserved command into a non-decision" deny "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output" 2>/dev/null)"
  expect_equal "guard: $bypass_variable=1 still logs both hook decisions" 2 "$(wc -l <"$risky_repository/.git/ai-engineering/guard-log.jsonl" 2>/dev/null | tr -d ' ')"
done
rm -f "$risky_repository/.git/ai-engineering/guard-log.jsonl"
output="$("$scripts/guard-bash.sh" --classify-only <<<"$lone_input")"
expect_equal "guard: --classify-only prints decision and classes" "ask
infrastructure-apply" "$output"
if [ -e "$risky_repository/.git/ai-engineering/guard-log.jsonl" ]; then fail "guard: --classify-only wrote a guard-log entry"; else pass; fi

gate_marker="$work_directory/gate-marker"
for gate_case in \
  "ask|terraform apply -auto-approve" \
  "deny|touch $gate_marker && terraform apply -auto-approve" \
  "deny|touch $gate_marker; git push --force origin feature"; do
  expected_decision="${gate_case%%|*}"
  jq -n --arg command "${gate_case#*|}" '{fast: $command}' >"$risky_repository/.agents/gates.json"
  rm -f "$gate_marker"
  output="$("$scripts/run-gate.sh" fast "$risky_repository")"; exit_code=$?
  expect_equal "run-gate: $expected_decision-class gate is refused" 5 "$exit_code"
  expect_contains "run-gate: $expected_decision refusal names the decision" "classified $expected_decision:" "$output"
  if [ -e "$gate_marker" ]; then fail "run-gate: refused $expected_decision gate still executed part of its command"; else pass; fi
done
jq -n --arg command "touch $gate_marker" '{fast: $command}' >"$risky_repository/.agents/gates.json"
output="$("$scripts/run-gate.sh" fast "$risky_repository")"; exit_code=$?
expect_equal "run-gate: safe gate still runs" 0 "$exit_code"
if [ -e "$gate_marker" ]; then pass; else fail "run-gate: safe gate did not run"; fi
rm -f "$gate_marker"
printf '%s\n' '{ "fast": "npm test && terraform apply -auto-approve" }' >"$risky_repository/.agents/gates.json"

# Regression (F2): with a trusted config ref, a committed change cannot define the gate
# that certifies it, and any change to that gate is surfaced in the verdict line.
certify_repository="$(new_repository certify-repo main)"
mkdir -p "$certify_repository/.agents"
printf '%s\n' '{ "full": "exit 1" }' >"$certify_repository/.agents/gates.json"
commit_all "$certify_repository" "base gate"
git -C "$certify_repository" checkout -q -b contribution
printf '%s\n' '{ "full": "true" }' >"$certify_repository/.agents/gates.json"
commit_all "$certify_repository" "contribution weakens its own gate"
output="$("$scripts/run-gate.sh" full "$certify_repository" main)"; exit_code=$?
expect_equal "run-gate: change cannot weaken the gate that certifies it" 1 "$exit_code"
expect_contains "run-gate: base gate command is used" "GATE full: FAILED (exit 1) command: exit 1 [gate config: committed at main;" "$output"
expect_contains "run-gate: modified gate is surfaced" "THIS CHANGE MODIFIES THE \"full\" GATE - review it: true" "$output"
output="$("$scripts/run-gate.sh" full "$certify_repository")"; exit_code=$?
expect_equal "run-gate: without a config ref HEAD is used" 0 "$exit_code"
git -C "$certify_repository" checkout -q main
output="$("$scripts/run-gate.sh" full "$certify_repository" main)"; exit_code=$?
expect_contains "run-gate: unchanged gate is attributed to the config ref" "[gate config: committed at main]" "$output"
case "$output" in *MODIFIES*) fail "run-gate: unchanged gate reported as modified" ;; *) pass ;; esac

git -C "$certify_repository" checkout -q -b gate-added-by-change
git -C "$certify_repository" rm -q .agents/gates.json
commit_all "$certify_repository" "no gates at base"
git -C "$certify_repository" checkout -q -b adds-own-gate
mkdir -p "$certify_repository/.agents"
printf '%s\n' '{ "full": "true" }' >"$certify_repository/.agents/gates.json"
commit_all "$certify_repository" "change adds its own gate"
output="$("$scripts/run-gate.sh" full "$certify_repository" gate-added-by-change)"; exit_code=$?
expect_equal "run-gate: gate added only by the change is not configured" 3 "$exit_code"
expect_contains "run-gate: added gate is surfaced" "THIS CHANGE MODIFIES THE \"full\" GATE" "$output"
git -C "$certify_repository" checkout -q gate-added-by-change
mkdir -p "$certify_repository/.agents"
printf '%s\n' '{ "full": "true" }' >"$certify_repository/.agents/gates.json"
output="$("$scripts/run-gate.sh" full "$certify_repository" gate-added-by-change)"; exit_code=$?
expect_equal "run-gate: uncommitted gate never stands in for the config ref" 3 "$exit_code"
output="$("$scripts/run-gate.sh" full "$certify_repository" no-such-ref)"; exit_code=$?
expect_equal "run-gate: unknown config ref is an error" 4 "$exit_code"

# ---------------------------------------------------------------- gate-fast (SubagentStop)
stop_input() { jq -n --arg id "$1" --arg cwd "$2" '{hook_event_name: "SubagentStop", agent_id: $id, agent_type: "ai-engineering:backend", cwd: $cwd}'; }
run_stop_hook() { stop_input "$1" "$2" | AI_ENGINEERING_HOOK_GATES=1 "$scripts/gate-fast.sh" 2>"$work_directory/stderr"; }

# Regression (F1): by default the hook never executes project code. Reproduces the
# reported path: a trusted committed gate command runs a script the agent edited.
hook_repository="$(new_repository hook-repo main)"
mkdir -p "$hook_repository/.agents" "$hook_repository/scripts"
printf '%s\n' '{ "fast": "bash scripts/test.sh" }' >"$hook_repository/.agents/gates.json"
printf '%s\n' 'exit 0' >"$hook_repository/scripts/test.sh"
commit_all "$hook_repository" "trusted gate"
printf 'touch "%s"\nexit 1\n' "$work_directory/hook-executed" >"$hook_repository/scripts/test.sh"
for opt_in_value in unset 0 true yes; do
  if [ "$opt_in_value" = unset ]; then
    stdout="$(stop_input agent-g "$hook_repository" | "$scripts/gate-fast.sh" 2>"$work_directory/stderr")"; exit_code=$?
  else
    stdout="$(stop_input agent-g "$hook_repository" | AI_ENGINEERING_HOOK_GATES="$opt_in_value" "$scripts/gate-fast.sh" 2>"$work_directory/stderr")"; exit_code=$?
  fi
  expect_equal "gate-fast: AI_ENGINEERING_HOOK_GATES=$opt_in_value lets the agent stop" 0 "$exit_code"
  expect_equal "gate-fast: AI_ENGINEERING_HOOK_GATES=$opt_in_value is silent" "" "$stdout$(cat "$work_directory/stderr")"
  if [ -e "$work_directory/hook-executed" ]; then fail "gate-fast: AI_ENGINEERING_HOOK_GATES=$opt_in_value executed project code"; else pass; fi
done
run_stop_hook agent-g "$hook_repository" >/dev/null; exit_code=$?
expect_equal "gate-fast: explicit opt-in runs the gate" 2 "$exit_code"
if [ -e "$work_directory/hook-executed" ]; then pass; else fail "gate-fast: explicit opt-in did not run the gate"; fi

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

# WORK-001 T3: both ask and deny classes are refused, and a refused command never runs any part.
review_marker="$work_directory/review-marker"
for review_case in \
  "ask|terraform apply -auto-approve" \
  "deny|touch $review_marker && terraform apply -auto-approve" \
  "deny|touch $review_marker; git push --force origin feature"; do
  expected_decision="${review_case%%|*}"
  set_review_command "${review_case#*|}"
  commit_all "$review_repository" "refused reviewer ($expected_decision)"
  rm -f "$review_marker"
  output="$(run_review "$review_repository")"; exit_code=$?
  expect_equal "external-review: $expected_decision-class reviewer is refused" 2 "$exit_code"
  expect_contains "external-review: $expected_decision refusal names the decision" "classified $expected_decision:" "$output"
  if [ -e "$review_marker" ]; then fail "external-review: refused $expected_decision reviewer still executed part of its command"; else pass; fi
done
set_review_command "touch $review_marker"
commit_all "$review_repository" "safe reviewer"
output="$(run_review "$review_repository")"; exit_code=$?
expect_equal "external-review: safe reviewer still runs" 0 "$exit_code"
if [ -e "$review_marker" ]; then pass; else fail "external-review: safe reviewer did not run"; fi
rm -f "$review_marker"

# ---------------------------------------------------------------- inject-standards
output="$(CLAUDE_PLUGIN_ROOT="$repository_directory/plugins/ai-engineering" "$scripts/inject-standards.sh")"
expect_contains "inject-standards: includes standards body" "# Engineering Standards" "$output"
case "$output" in *"user-invocable"*) fail "inject-standards: frontmatter leaked into context" ;; *) pass ;; esac

echo "tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
