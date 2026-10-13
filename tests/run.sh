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

# Performance: generous bounds for CI machines. Design targets (spec, amended in WORK-001 fix
# round 3): typical commands p95 under 150 ms; cost linear in the number of commands with an
# explicit per-command bound; heredoc- or data-dominated input up to 256 KB under 1 s. Each test
# checks its own fixture (byte size or exact command count) so it stays genuine.
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
# A real 8 KB command (the fixture was 3.5 KB before fix round 2): 140 two-command pipelines.
{ i=0; while [ "$i" -lt 140 ]; do printf 'grep -rn "foo\\|bar" --include=*.ts src/app%s | head -5 && ' "$i"; i=$((i + 1)); done; printf 'echo done'; } >"$work_directory/command-8k.txt"
command_8k_bytes="$(wc -c <"$work_directory/command-8k.txt" | tr -d ' ')"
if [ "$command_8k_bytes" -ge 8000 ] && [ "$command_8k_bytes" -le 8192 ]; then pass; else fail "performance: 8 KB fixture is $command_8k_bytes bytes"; fi
jq -n --rawfile command "$work_directory/command-8k.txt" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/command-8k.json"
medium_ms="$(elapsed_milliseconds "$work_directory/command-8k.json")"
echo "info: guard timing, single run: ${heredoc_bytes}-byte heredoc ${heredoc_ms} ms, ${command_8k_bytes}-byte command ${medium_ms} ms"
if [ "$medium_ms" -lt 500 ]; then pass; else fail "performance: 8 KB command took ${medium_ms} ms (budget 150 ms, tolerance 500 ms)"; fi
# 1. Typical commands: p95 of 20 runs under 150 ms (CI tolerance 500 ms, as above).
printf 'nvm use && npm test && git status --short && grep -rn "x" src' >"$work_directory/command-typical.txt"
jq -n --rawfile command "$work_directory/command-typical.txt" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/command-typical.json"
expect_equal "performance: the typical fixture is four commands" 3 "$(grep -o '&&' "$work_directory/command-typical.txt" | wc -l | tr -d ' ')"
typical_p95_ms="$(i=0; while [ "$i" -lt 20 ]; do elapsed_milliseconds "$work_directory/command-typical.json"; i=$((i + 1)); done | sort -n | sed -n 19p)"
if [ "$typical_p95_ms" -lt 500 ]; then pass; else fail "performance: typical command p95 ${typical_p95_ms} ms (budget 150 ms, tolerance 500 ms)"; fi
# 2. Per-command scaling: the marginal cost per command between 70 and 280 two-command pipelines
# (which cancels the fixed jq compile and wrapper cost) is at most 1.5 ms. Measured on the
# development machine: about 0.45 ms per command (0.86/0.87/0.91 ms per pipeline for 35-70,
# 70-140 and 140-280 pipelines); 1.5 ms is about three times that, the same headroom as the other
# CI tolerances. Growth must also stay linear: the 140-280 marginal at most twice the 70-140 one
# (plus 0.2 ms for timer resolution), which a quadratic cost would exceed. Minimum of 3 runs each.
scaling_fixture() {
  { local i=0; while [ "$i" -lt "$1" ]; do printf 'grep -rn "foo\\|bar" --include=*.ts src/app%s | head -5 && ' "$i"; i=$((i + 1)); done; printf 'echo done'; } >"$work_directory/scale-$1.txt"
  jq -n --rawfile command "$work_directory/scale-$1.txt" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/scale-$1.json"
}
scaling_commands() { echo $(( $(grep -o 'grep -rn' "$work_directory/scale-$1.txt" | wc -l) + $(grep -o '| head -5' "$work_directory/scale-$1.txt" | wc -l) + $(grep -o 'echo done' "$work_directory/scale-$1.txt" | wc -l) )); }
scaling_ms() { local i=0; while [ "$i" -lt 3 ]; do elapsed_milliseconds "$work_directory/scale-$1.json"; i=$((i + 1)); done | sort -n | head -n 1; }
for pipelines in 70 140 280; do
  scaling_fixture "$pipelines"
  expect_equal "performance: the $pipelines-pipeline fixture has exactly $((pipelines * 2 + 1)) commands" "$((pipelines * 2 + 1))" "$(scaling_commands "$pipelines")"
done
scale_70_ms="$(scaling_ms 70)" scale_140_ms="$(scaling_ms 140)" scale_280_ms="$(scaling_ms 280)"
# Microseconds per command, integer arithmetic.
marginal_us=$(( (scale_280_ms - scale_70_ms) * 1000 / (561 - 141) ))
low_marginal_us=$(( (scale_140_ms - scale_70_ms) * 1000 / (281 - 141) ))
high_marginal_us=$(( (scale_280_ms - scale_140_ms) * 1000 / (561 - 281) ))
echo "info: guard scaling: 141/281/561 commands ${scale_70_ms}/${scale_140_ms}/${scale_280_ms} ms; marginal ${marginal_us} us per command (bound 1500 us)"
if [ "$marginal_us" -le 1500 ]; then pass; else fail "performance: marginal cost ${marginal_us} us per command (bound 1500 us)"; fi
if [ "$high_marginal_us" -le $((low_marginal_us * 2 + 200)) ]; then pass; else fail "performance: cost per command grows with size (${low_marginal_us} us, then ${high_marginal_us} us)"; fi
# 3. Large inert input: the ~250 KB heredoc above (its byte size is asserted) stays under 1 s
# (CI tolerance 2500 ms, above), whatever its line count.
# A pathological command is cut off by the time budget or the fallback and still decides safely.
pathological_file="$work_directory/pathological.txt"
# shellcheck disable=SC2016 # the literal text `$((` is the pathological command under test
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

# ---------------------------------------------------------------- agent_type policy, authority store, shell-edit hint
# Table cases are "agent|expected|command". Agents: m main session (no agent_type), b backend,
# f frontend, p platform, q qa, s security-reviewer, l learning, o another agent type.
agent_repository="$(new_repository agent-repo feature)"
mkdir -p "$agent_repository/src" "$agent_repository/.agents/specs/active"
printf 'x\n' >"$agent_repository/src/app.ts"
git -C "$agent_repository" add -A && git -C "$agent_repository" -c user.name=test -c user.email=test@example.com commit -q -m files
agent_name() {
  case "$1" in
    m) echo "" ;; b) echo ai-engineering:backend ;; f) echo ai-engineering:frontend ;; p) echo ai-engineering:platform ;;
    q) echo ai-engineering:qa ;; s) echo ai-engineering:security-reviewer ;; l) echo ai-engineering:learning ;;
    *) echo ai-engineering:other ;;
  esac
}
agent_input() { jq -n --arg command "${1//\\n/$'\n'}" --arg cwd "$2" --arg agent "$(agent_name "$3")" '{tool_input: {command: $command}, cwd: $cwd} + (if $agent == "" then {} else {agent_type: $agent} end)'; }
agent_output() { agent_input "$1" "$2" "$3" | "$scripts/guard-bash.sh"; }
hint_of() { jq -r '.hookSpecificOutput.additionalContext // "none"' 2>/dev/null <<<"$1" | grep . || echo none; }

# Git writes by subagents: denied for specialists, unaffected for the main session and other agents.
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "agent policy ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
b|deny|git commit -m x
b|deny|git push -u origin work
b|deny|git push origin main
b|none|git status
b|none|git diff --stat
m|none|git commit -m x
m|none|git add . && git commit -m x
o|none|git commit -m x
q|deny|git stash
f|deny|git commit -m x
p|deny|git commit -m x
q|deny|git commit -m x
s|deny|git commit -m x
l|deny|git commit -m x
b|none|git log --oneline -5
b|none|git show HEAD
b|none|git blame src/app.ts
b|none|git grep needle
b|none|git ls-files
b|none|git rev-parse HEAD
b|none|git merge-base main HEAD
b|none|git branch
b|none|git branch --list
b|none|git branch -a
b|none|git branch --show-current
b|none|git stash list
b|none|git stash show
b|none|git tag
b|none|git tag -l
b|none|git worktree list
b|deny|git checkout
b|deny|git add .
b|deny|git merge other
b|deny|git rebase main
b|deny|git reset --hard
b|deny|git restore src/app.ts
b|deny|git checkout -- src/app.ts
b|deny|git checkout other
b|deny|git checkout -b newbranch
b|deny|git switch other
b|deny|git switch -c newbranch
b|deny|git branch -d old
b|deny|git branch -D old
b|deny|git branch -m old new
b|deny|git branch newbranch
b|deny|git tag v1
b|deny|git tag -a v1 -m release
b|deny|git stash
b|deny|git stash pop
b|deny|git cherry-pick abc
b|deny|git revert abc
b|deny|git am patch.mbox
b|deny|git apply change.patch
b|deny|git worktree add ../other
b|deny|git worktree remove ../other
b|deny|git update-ref refs/heads/x HEAD
b|deny|git gc
b|deny|git prune
b|deny|git pull
b|deny|git -C elsewhere commit -m x
b|deny|git -c user.name=a commit -m x
b|deny|git --no-pager add .
b|deny|bash -c 'git push origin work'
b|deny|sh -c "git commit -m x"
b|deny|env git commit -m x
b|deny|/usr/bin/git add .
b|deny|GIT add .
b|deny|'git' "commit" -m x
b|deny|command git commit -m x
b|deny|sudo git commit -m x
b|deny|cd src && git add .
b|deny|git status && git commit -m x
b|deny|git status; git add .
b|deny|echo $(git add .)
b|deny|(git add .)
b|deny|for f in a b; do git add $f; done
b|deny|git log | git commit -F -
b|deny|git status\ngit add .
CASES
reason="$(agent_input 'git commit -m x' "$agent_repository" b | "$scripts/guard-bash.sh" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
expect_contains "agent policy: reason names the operation" "git commit" "$reason"
expect_contains "agent policy: reason says the coordinator owns Git" "coordinator owns Git" "$reason"
expect_contains "agent policy: reason states guardrail limits" "not a sandbox" "$reason"

# Authority store: denied for every caller, reads are not.
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "authority store ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
m|deny|echo '{}' > .agents/specs/active/WORK-9.state.json
b|deny|echo '{}' > .agents/specs/active/WORK-9.state.json
q|deny|echo '{}' > .agents/specs/active/WORK-9.state.json
l|deny|echo '{}' > .agents/specs/active/WORK-9.state.json
m|deny|echo x >> .agents/specs/active/WORK-9.state.json
m|deny|echo x >| .agents/specs/active/WORK-9.state.json
m|deny|echo x &> .agents/specs/active/WORK-9.state.json
m|deny|echo x 1> .agents/specs/active/WORK-9.state.json
m|deny|echo x 2> .agents/specs/active/WORK-9.state.json
m|deny|echo x >& .agents/specs/active/WORK-9.state.json
m|deny|> .agents/specs/active/WORK-9.state.json
m|deny|cat > .agents/specs/active/WORK-9.state.json <<'EOF'\n{}\nEOF
m|deny|echo x | tee .agents/specs/active/WORK-9.state.json
m|deny|tee -a .agents/specs/active/WORK-9.state.json < x.json
m|deny|cp x .agents/specs/active/WORK-9.state.json
m|deny|cp -t .agents/specs/active x.json .agents/specs/active/WORK-9.state.json
m|deny|mv x.json .agents/specs/active/WORK-9.state.json
m|deny|mv .agents/specs/active/WORK-9.state.json /tmp/gone
m|deny|ln -s x .agents/specs/active/WORK-9.state.json
m|deny|install x .agents/specs/active/WORK-9.state.json
m|deny|rsync x .agents/specs/active/WORK-9.state.json
m|deny|sed -i s/a/b/ .agents/specs/active/WORK-9.state.json
m|deny|sed -i.bak s/a/b/ .agents/specs/active/WORK-9.state.json
m|deny|perl -pi -e s/a/b/ .agents/specs/active/WORK-9.state.json
m|deny|truncate -s 0 .agents/specs/active/WORK-9.state.json
m|deny|rm .agents/specs/active/WORK-9.state.json
m|deny|rm -f .agents/specs/active/*.state.json
m|deny|dd if=x of=.agents/specs/active/WORK-9.state.json
m|deny|python3 -c "open('.agents/specs/active/WORK-9.state.json','w').write('{}')"
m|deny|python3 tool.py .agents/specs/active/WORK-9.state.json
m|deny|node -e "require('fs').writeFileSync('.agents/specs/active/WORK-9.state.json','{}')"
m|deny|python3 - <<'EOF'\nopen('.agents/specs/active/WORK-9.state.json','w').write('{}')\nEOF
m|deny|bash -c "echo x > .agents/specs/active/WORK-9.state.json"
m|deny|cd .agents/specs/active && echo x > WORK-9.state.json
m|deny|echo x > ./.agents/specs/../specs/active/WORK-9.state.json
m|deny|echo x > .agents/specs/active//WORK-9.state.json
m|deny|echo x > "$PWD/.agents/specs/active/WORK-9.state.json"
m|deny|echo x > .agents/specs/active/nested/dir/WORK-9.state.json
m|deny|cp x .git/ai-engineering/tokens/t
m|deny|echo x > .git/ai-engineering/tokens/t
m|deny|echo x > ../.git/ai-engineering/tokens/t
m|deny|echo x > /somewhere/store.git/ai-engineering/tokens/t
m|deny|cd .git && echo x > ai-engineering/tokens/t
m|deny|rm -rf .git/ai-engineering/tokens
m|deny|rm -rf .git/ai-engineering
m|deny|rm .git/ai-engineering/tokens/*
m|deny|mv .git/ai-engineering/tokens /tmp/tokens
m|deny|ln -s .git/ai-engineering/tokens elsewhere
m|deny|python3 -c "open('.git/ai-engineering/tokens/t','w').write('x')"
b|deny|cp x .git/ai-engineering/tokens/t
m|none|cat .agents/specs/active/WORK-9.state.json
m|none|jq . .agents/specs/active/WORK-9.state.json
m|none|jq .status .agents/specs/active/WORK-9.state.json > /tmp/status.json
m|none|grep status .agents/specs/active/WORK-9.state.json
m|none|less .agents/specs/active/WORK-9.state.json
m|none|cat .git/ai-engineering/tokens/t
m|none|ls .git/ai-engineering/tokens
m|none|cp .git/ai-engineering/tokens/t /tmp/copy
m|none|cp .agents/specs/active/WORK-9.state.json /tmp/copy
m|none|cat .agents/specs/active/WORK-9.state.json 2>/dev/null
m|none|cat .agents/specs/active/WORK-9.state.json 2>&1
m|none|echo x > .agents/specs/active/WORK-9.md
m|none|echo x > notes/state.json
m|none|rm .agents/specs/active/WORK-9.md
CASES
reason="$(agent_input "echo '{}' > .agents/specs/active/WORK-9.state.json" "$agent_repository" m | "$scripts/guard-bash.sh" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
expect_contains "authority store: reason names the transition script" "plugin's transition script" "$reason"
# A deny from the authority store beats a hint, and an unparsable command that names it asks (fallback).
expect_equal "authority store: unbalanced quote naming the store asks" ask "$(decision_of "$(agent_output "echo 'x > .agents/specs/active/WORK-9.state.json" "$agent_repository" m)")"

# Worktree and separate Git directory: the token store is under the Git common directory.
store_main="$(new_repository store-main feature)"
git -C "$store_main" worktree add -q "$work_directory/store-wt" -b store-wt >/dev/null 2>&1
physical_main="$(cd "$store_main" && pwd -P)"
mkdir -p "$store_main/.git/ai-engineering/tokens"
while IFS='|' read -r expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "authority store from a worktree: $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$work_directory/store-wt" m)")"
done <<CASES
deny|echo x > $physical_main/.git/ai-engineering/tokens/t
deny|echo x > .git/ai-engineering/tokens/t
deny|echo x > ../store-main/.git/ai-engineering/tokens/t
none|cat $physical_main/.git/ai-engineering/tokens/t
CASES
while IFS='|' read -r expected target; do
  [ -n "$expected" ] || continue
  expect_equal "guard-writes from a worktree: $target" "$expected" "$(decision_of "$(write_input b "$target" "$work_directory/store-wt" | "$scripts/guard-writes.sh")")"
done <<CASES
deny|$physical_main/.git/ai-engineering/tokens/t
deny|$work_directory/store-wt/.git/ai-engineering/tokens/t
deny|../store-main/.git/ai-engineering/tokens/t
none|$work_directory/store-wt/src/app.ts
CASES
separate_repository="$work_directory/separate-repo"
mkdir -p "$separate_repository"
git -C "$separate_repository" init -q -b main --separate-git-dir "$work_directory/elsewhere-store" >/dev/null 2>&1
mkdir -p "$work_directory/elsewhere-store/ai-engineering/tokens"
physical_store="$(cd "$work_directory/elsewhere-store" && pwd -P)"
expect_equal "guard-writes: token store in a git dir not named .git" deny "$(decision_of "$(write_input m "$physical_store/ai-engineering/tokens/t" "$separate_repository" | "$scripts/guard-writes.sh")")"
expect_equal "guard-bash: token store in a git dir not named .git" deny "$(decision_of "$(agent_output "echo x > $physical_store/ai-engineering/tokens/t" "$separate_repository" m)")"
expect_equal "guard-writes: an unrelated tokens directory is not the store" none "$(decision_of "$(write_input m "$separate_repository/ai-engineering/tokens/t" "$separate_repository" | "$scripts/guard-writes.sh")")"

# Write/Edit/NotebookEdit: the authority store is denied for every caller.
state_repository="$agent_repository"
physical_state_repository="$(cd "$state_repository" && pwd -P)"
mkdir -p "$state_repository/.agents/learnings"
printf '{}\n' >"$state_repository/.agents/specs/active/WORK-9.state.json"
ln -sfn "$physical_state_repository/.agents/specs/active" "$state_repository/linked-specs"
ln -sfn "$physical_state_repository/.agents/specs/active/WORK-9.state.json" "$state_repository/linked-state.json"
while IFS='|' read -r expected agent target; do
  [ -n "$expected" ] || continue
  expect_equal "guard-writes authority: $agent -> $target" "$expected" "$(decision_of "$(write_input "$agent" "$target" "$state_repository" | "$scripts/guard-writes.sh")")"
done <<CASES
deny||$state_repository/.agents/specs/active/WORK-9.state.json
deny||.agents/specs/active/WORK-9.state.json
deny||./.agents/specs/active/WORK-9.state.json
deny||src/../.agents/specs/active/WORK-9.state.json
deny||$state_repository/src/../.agents/specs/active/WORK-9.state.json
deny||$state_repository/.agents/specs/active/not-yet/WORK-10.state.json
deny||$state_repository/linked-specs/WORK-9.state.json
deny||$state_repository/linked-state.json
deny||$state_repository/nonexistent/../.agents/specs/active/WORK-9.state.json
deny|ai-engineering:backend|$state_repository/.agents/specs/active/WORK-9.state.json
deny|ai-engineering:qa|$state_repository/.agents/specs/active/WORK-9.state.json
deny|ai-engineering:learning|$state_repository/.agents/specs/active/WORK-9.state.json
deny|ai-engineering:learning|.agents/specs/WORK-9.state.json
deny||$state_repository/.git/ai-engineering/tokens/t
deny|ai-engineering:backend|.git/ai-engineering/tokens/t
deny||.git/ai-engineering/tokens
none||$state_repository/.agents/specs/active/WORK-9.md
none|ai-engineering:backend|$state_repository/src/app.ts
none|ai-engineering:learning|$state_repository/.agents/learnings/entry.md
deny|ai-engineering:learning|$state_repository/src/app.ts
CASES
notebook_output="$(jq -n --arg path "$state_repository/.agents/specs/active/WORK-9.state.json" --arg cwd "$state_repository" '{agent_type: "ai-engineering:backend", tool_input: {notebook_path: $path}, cwd: $cwd}' | "$scripts/guard-writes.sh")"
expect_equal "guard-writes authority: NotebookEdit path" deny "$(decision_of "$notebook_output")"
expect_contains "guard-writes authority: reason names the transition script" "plugin's transition script" "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$notebook_output")"

# Guard log: the new denies are logged with their class; the hint is not a decision and is not logged.
agent_log_repository="$(new_repository agent-log-repo feature)"
agent_log_file="$agent_log_repository/.git/ai-engineering/guard-log.jsonl"
agent_output 'git commit -m x' "$agent_log_repository" b >/dev/null
expect_equal "guard log: git write by a subagent is logged with its class" git-write-by-subagent "$(tail -n 1 "$agent_log_file" | jq -r '.classes | join(",")')"
expect_equal "guard log: git write by a subagent is logged as a deny" deny "$(tail -n 1 "$agent_log_file" | jq -r .decision)"
agent_output "echo x > .agents/specs/active/WORK-9.state.json" "$agent_log_repository" m >/dev/null
expect_equal "guard log: authority store write is logged with its class" authority-store-write "$(tail -n 1 "$agent_log_file" | jq -r '.classes | join(",")')"
log_lines_before="$(wc -l <"$agent_log_file" | tr -d ' ')"
agent_output "sed -i s/a/b/ f.ts" "$agent_log_repository" b >/dev/null
expect_equal "guard log: the shell-edit hint is not logged" "$log_lines_before" "$(wc -l <"$agent_log_file" | tr -d ' ')"

# Shell-edit hint: "Use Edit/Write for file changes." as context for implementation agents,
# never a decision. Table cases are "agent|hint or none|command".
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  output="$(agent_output "$command_text" "$agent_repository" "$agent")"
  expect_equal "shell-edit hint ($agent): $command_text" "$expected" "$(hint_of "$output")"
  case "$expected" in
    none) ;;
    *) expect_equal "shell-edit hint is not a decision ($agent): $command_text" none "$(decision_of "$output")" ;;
  esac
done <<'CASES'
b|Use Edit/Write for file changes.|sed -i s/a/b/ src/app.ts
b|Use Edit/Write for file changes.|sed -i.bak s/a/b/ src/app.ts
b|Use Edit/Write for file changes.|perl -pi -e s/a/b/ src/app.ts
b|Use Edit/Write for file changes.|sed -i 's/a/in-memory limit is per-instance on serverless platforms; remove the entry/' f.ts
b|Use Edit/Write for file changes.|python3 -c "open('f.ts','w').write('in-memory limit is per-instance on serverless platforms; remove the entry')"
b|Use Edit/Write for file changes.|python3 - <<'EOF'\nfrom pathlib import Path\nPath('a.ts').write_text('x')\nEOF
b|Use Edit/Write for file changes.|node -e "require('fs').writeFileSync('a.ts', 'x')"
b|Use Edit/Write for file changes.|echo x > src/app.ts
b|Use Edit/Write for file changes.|cat >> src/app.ts <<'EOF'\nmore\nEOF
b|Use Edit/Write for file changes.|cd src && sed -i s/a/b/ app.ts
f|Use Edit/Write for file changes.|sed -i s/a/b/ src/app.ts
p|Use Edit/Write for file changes.|sed -i s/a/b/ src/app.ts
m|none|sed -i s/a/b/ src/app.ts
m|none|python3 -c "open('f.ts','w').write('x')"
q|none|sed -i s/a/b/ src/app.ts
l|none|sed -i s/a/b/ src/app.ts
o|none|sed -i s/a/b/ src/app.ts
b|none|echo x > brand-new-file.txt
b|none|echo x > /tmp/out.txt
b|none|echo x > /dev/null
b|none|echo x >> build.log
b|none|ls src
b|none|cat src/app.ts
b|none|sed s/a/b/ src/app.ts
b|none|sed -n 1,5p src/app.ts
b|none|python3 -c "print('hello')"
b|none|python3 -c "import sys; sys.stdout.write('x')"
b|none|python3 -c "print(open('src/app.ts').read())"
b|none|git status
b|none|pnpm test
b|none|sed -i s/a/b/ src/app.ts; terraform apply
b|none|echo x > .agents/specs/active/WORK-9.state.json
CASES
# A real decision wins over the hint.
expect_equal "shell-edit hint: an ask wins over the hint" ask "$(decision_of "$(agent_output 'terraform apply' "$agent_repository" b)")"
expect_equal "shell-edit hint: a deny wins over the hint" deny "$(decision_of "$(agent_output 'sed -i s/a/b/ src/app.ts && git add .' "$agent_repository" b)")"
expect_equal "shell-edit hint: a git write deny leaves no hint" none "$(hint_of "$(agent_output 'sed -i s/a/b/ src/app.ts && git add .' "$agent_repository" b)")"
expect_equal "shell-edit hint: the Landra case by the main session is no decision" none "$(decision_of "$(agent_output "python3 -c \"open('f.ts','w').write('in-memory limit is per-instance on serverless platforms; remove the entry')\"" "$agent_repository" m)")"
expect_equal "shell-edit hint: the Landra case by the main session has no hint" none "$(hint_of "$(agent_output "sed -i 's/a/per-instance on serverless platforms; remove the entry/' f.ts" "$agent_repository" m)")"

# ---------------------------------------------------------------- WORK-001 fix round 1 (security review)
# Table cases are "agent|expected|command" (see the agent letters above); "\n" is a newline.
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "fix round ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
m|ask|function f { terraform apply; }
m|ask|function f() { terraform apply; }
m|ask|coproc terraform apply
m|ask|coproc NAME { terraform apply; }
m|ask|watch terraform apply
m|ask|watch -n 5 'terraform apply'
m|ask|script -c 'terraform apply' /dev/null
m|ask|script -q /dev/null terraform apply
m|ask|bash -o pipefail -c 'terraform apply'
m|ask|bash -O extglob -c 'terraform apply'
m|ask|echo 'terraform apply' | bash -
m|ask|echo 'terraform apply' | bash -s
m|ask|cat <<'X' | bash\nterraform apply\nX
m|ask|alias x='terraform apply'; x
m|ask|source /dev/stdin <<< 'terraform apply'
m|ask|. /dev/stdin <<< 'terraform apply'
m|ask|source <(echo 'terraform apply')
m|ask|. <(echo 'terraform apply')
m|ask|bash <(echo 'terraform apply')
m|ask|bash <<< 'terraform apply'
m|ask|caffeinate -i terraform apply
m|ask|chronic terraform apply
m|ask|flock /tmp/l terraform apply
m|ask|flock -n /tmp/l -c 'terraform apply'
m|ask|unbuffer terraform apply
m|ask|chrt -f 1 terraform apply
m|ask|taskset 0x1 terraform apply
m|ask|ionice -c 3 terraform apply
m|ask|env -S 'terraform apply'
m|ask|env --split-string='terraform apply'
m|ask|env --split-string 'terraform apply'
m|ask|su -c 'terraform apply' root
m|ask|nix-shell --run 'terraform apply'
m|ask|parallel terraform apply ::: a b
m|ask|parallel {} ::: 'terraform apply'
m|ask|find . -exec terraform apply \;
m|ask|find . -execdir sh -c 'terraform apply' +
m|ask|docker exec db psql -c 'DROP TABLE x'
m|ask|docker exec -it -u root db psql -c 'DROP TABLE x'
m|ask|docker compose exec db psql -c 'DROP TABLE x'
m|ask|docker-compose exec -T db psql -c 'DROP TABLE x'
m|ask|podman exec db psql -c 'DROP TABLE x'
m|ask|kubectl exec pod -- psql -c 'DROP TABLE x'
m|ask|kubectl exec -n ns pod psql -c 'DROP TABLE x'
m|ask|npx prisma db execute --stdin <<< 'DROP TABLE x'
m|ask|deno eval 'sql`DROP TABLE x`'
m|ask|bun -e 'sql`DROP TABLE x`'
m|ask|bun eval 'sql`DROP TABLE x`'
m|ask|pnpm vercel --prod
m|ask|yarn vercel --prod
m|ask|sudo -iu root terraform apply
m|ask|sudo -u root -E terraform apply
m|ask|foo-runner terraform apply
m|ask|./run terraform apply
m|ask|my-tool kubectl delete pod x
m|none|echo terraform apply
m|none|printf 'git push --force' > notes.txt
m|none|cat notes.md | grep 'npm publish'
m|none|git commit -m 'release the deploy and publish notes'
m|none|python3 -c "print('terraform apply')"
m|none|jq . package.json
m|none|ls scripts
m|ask|TERRAFORM apply
m|ask|Terraform apply
m|ask|GIT push --force origin feature
m|ask|CURL -X POST https://api.github.com/repos/o/r/releases
m|ask|GH pr merge 1
m|ask|PSQL -c 'DROP TABLE x'
m|ask|VERCEL --prod
m|ask|NETLIFY deploy --prod
m|ask|KUBECTL delete pod x
m|ask|git $(echo push) --force origin feature
m|ask|git push $(echo --force) origin feature
m|ask|git push ${FLAG:---force} origin feature
m|ask|curl -X $(echo POST) https://api.github.com/repos/o/r/releases
m|ask|curl -X POST https://api.github.com/repos/o/r/$(echo releases)
m|ask|curl -X ${METHOD} https://api.github.com/repos/o/r/releases
m|ask|terraform $(echo apply)
m|none|git -C "$DIR" status
m|none|git commit -m "$(date)"
m|none|curl -s "https://api.github.com/repos/$OWNER/r/releases/latest"
m|ask|git -c alias.p='push --force' p origin feature
m|ask|git -c alias.p='!git push --force' p
m|none|git --config-env=alias.p=VAR p origin feature
b|deny|git -c alias.c=commit c -m x
m|ask|npx netlify-cli deploy --prod
m|ask|npx vercel@latest --prod
m|ask|npx neonctl@latest branches delete br-1
m|ask|pnpm dlx vercel@33 deploy --prod
m|ask|curl -X PATCH https://api.github.com/repos/o/r/git/refs/heads/main -d '{"force":true}'
m|ask|curl -X PATCH https://api.github.com/repos/o/r/git/refs/heads/x -d '{"force":true}'
m|ask|curl -X POST https://api.github.com/repos/o/r/git/refs -d x
m|ask|gh api -X PATCH repos/o/r/git/refs/heads/x -f sha=y
m|none|curl https://api.github.com/repos/o/r/git/refs/heads/x
m|deny|export X=$(rm -rf y); terraform apply
m|deny|rm -rf y | terraform apply
m|deny|rm -rf $(terraform apply)
m|deny|terraform apply | tee out.log
m|ask|terraform apply 2>&1 | tail -5
m|ask|echo 'TRUNCATE t' | psql
m|ask|cd x && terraform apply
m|ask|terraform apply -var x=$(date)
m|ask|export V=$(git describe) && terraform apply
m|ask|X=$(terraform apply)
m|ask|echo $(terraform apply)
m|deny|echo start\nterraform apply\necho done
m|ask|git push --follow-tags origin feature
m|ask|gh pr -R o/r merge 1
m|ask|gh release --repo x create v1
m|ask|neonctl branches --project-id p delete br-1
m|ask|vercel redeploy dpl_1
m|ask|vercel alias set x.vercel.app example.com
m|none|vercel alias ls
m|ask|dropdb mydb
m|ask|mysqladmin drop mydb
m|ask|npx prisma migrate reset --force
m|ask|neonctl branches reset br-1 --parent
m|ask|neonctl branches restore br-1 ^self@2026-10-01
m|ask|gh repo delete o/r --yes
m|ask|netlify env:unset X
m|ask|vercel env add X production
m|ask|vercel env rm X production
m|none|vercel env ls
m|ask|gh release upload v1 f
m|ask|gh workflow run deploy.yml
m|ask|gh workflow run release.yml --ref main
m|none|gh workflow run ci.yml
m|ask|gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: "x"}) { clientMutationId } }'
m|ask|psql -c 'DROP/**/TABLE x'
m|ask|psql -c 'drop /* c */ table x'
m|deny|cat > f.sql <<'EOF'\nDROP TABLE x;\nEOF\npsql -f f.sql
m|deny|cat > f.sh <<'EOF'\nterraform apply\nEOF\nbash f.sh
m|none|psql -c 'select 1'
m|none|psql -c 'select 1 -- DROP is not run'
b|deny|git config core.hooksPath x
b|deny|git branch -v nb
b|deny|git branch --sort=x nb
b|deny|git branch --abbrev nb
b|deny|git branch --column nb
b|deny|git branch --format=x nb
b|deny|git tag --sort=x nb
b|deny|git update-index --assume-unchanged f
b|deny|git notes add -m x
b|deny|git commit-tree HEAD^{tree} -m x
b|deny|git symbolic-ref HEAD refs/heads/x
b|deny|git filter-branch -f
b|deny|git replace a b
b|deny|git submodule update --init
b|deny|git init
b|deny|git lfs push origin x
b|deny|git subtree push --prefix=x origin y
b|deny|git remote add o u
b|deny|git remote set-url origin u
b|deny|git config user.name x
b|deny|git config --global user.name x
b|deny|git config --get user.name --add
b|deny|git -c core.pager='sh -c x' log
b|deny|git -c core.sshCommand=x fetch
b|ask|git "$SUB" -m x
b|deny|git clone x
b|deny|git reflog expire --all
b|none|git fetch origin
b|none|git remote
b|none|git remote -v
b|none|git remote show origin
b|none|git remote get-url origin
b|none|git config --get user.name
b|none|git config --get-regexp 'alias.*'
b|none|git config --list
b|none|git config -l
b|none|git branch --list 'f*'
b|none|git branch -l
b|none|git branch --contains HEAD
b|none|git branch --merged main
b|none|git branch -a
b|none|git branch -vv
b|none|git branch --sort=-committerdate
b|none|git branch --sort -committerdate
b|none|git tag -n
b|none|git tag --contains HEAD
b|none|git tag -l 'v*'
b|none|git tag --list --sort=-v:refname
b|none|git rev-list --count HEAD
b|none|git describe --tags
b|none|git ls-tree HEAD
b|none|git cat-file -p HEAD
b|none|git shortlog -sn
b|none|git stash show
b|none|git --version
b|none|git help log
b|deny|echo x > .git/hooks/pre-commit
b|deny|cp x .git/hooks/post-commit
b|deny|echo x >> .git/config
b|deny|tee .git/info/exclude < x
b|deny|git diff --output=.git/hooks/pre-commit
q|deny|echo x > .git/info/exclude
l|deny|echo x > .git/hooks/pre-push
m|none|echo x > .git/info/exclude
m|none|git diff --output=out.patch
b|none|echo x > build/hooks/pre-commit
b|ask|$(echo git) commit -m x
b|ask|echo "unbalanced; git commit -m x
b|none|echo "unbalanced; git status
m|ask|echo 'unbalanced; terraform apply
m|ask|echo 'unbalanced; curl -X POST https://api.github.com/repos/o/r/releases
m|deny|echo x > .agents/specs/active/WORK-9.STATE.JSON
m|deny|echo x > .Agents/Specs/Active/WORK-9.State.Json
m|deny|echo x > .git/AI-Engineering/Tokens/t
m|deny|cp x .GIT/ai-engineering/TOKENS/t
m|deny|echo x > .agents/specs/active/WORK-9.state.js?n
m|deny|echo x > .agents/specs/active/WORK-9.state.[j]son
m|deny|echo x > .agents/specs/active/WORK-9.state.{json,x}
m|deny|echo x > .agents/specs/*/WORK-9.state.json
m|deny|rm -f .agents/specs/active/WORK-*
m|deny|rm .git/ai-engineering/tokens/t*
m|deny|cd .git/ai-engineering/tokens && echo x > t
m|deny|cd .git && echo x > ai-engineering/tokens/t
m|deny|pushd .git/ai-engineering; echo x > tokens/t
m|deny|cd .agents/specs/active; touch notes.state.json
m|deny|cd .git/ai-engineering/tokens; rm t
m|deny|tar -xf a.tar -C .git/ai-engineering/tokens
m|deny|tar xf a.tar -C .git
m|deny|tar --extract --directory=.git/ai-engineering -f a.tar
m|deny|unzip a.zip -d .git/ai-engineering
m|deny|patch .agents/specs/active/WORK-9.state.json < p.diff
m|deny|patch -d .git/ai-engineering/tokens < p.diff
m|deny|git apply <<'EOF'\n--- a/.agents/specs/active/WORK-9.state.json\n+++ b/.agents/specs/active/WORK-9.state.json\nEOF
m|deny|git checkout HEAD -- .agents/specs/active/WORK-9.state.json
m|deny|git restore --source=HEAD~1 .agents/specs/active/WORK-9.state.json
m|deny|git restore -s HEAD~1 .agents/specs/active/WORK-9.state.json
m|deny|curl -o .agents/specs/active/WORK-9.state.json https://x.example/y
m|deny|curl --output .agents/specs/active/WORK-9.state.json https://x.example/y
m|deny|curl -O --output-dir .git/ai-engineering/tokens https://x.example/t
m|deny|curl -O https://x.example/WORK-9.state.json
m|deny|wget -O .git/ai-engineering/tokens/t https://x.example/y
m|deny|wget -P .git/ai-engineering/tokens https://x.example/t
m|deny|echo x | sponge .agents/specs/active/WORK-9.state.json
m|deny|cp -r x .git/
m|deny|cp -r x .git
m|deny|rsync -a x/ .git/ai-engineering/
m|deny|mkdir -p .git/ai-engineering/tokens
m|deny|mkdir .git/ai-engineering
m|deny|ln -s /tmp/x .git/ai-engineering
m|deny|ln -s /tmp/x .git/ai-engineering/tokens
m|deny|rm -rf .agents
m|deny|rm -rf .agents/specs
m|deny|rm -rf .agents/specs/active
m|deny|rm -rf .git
m|deny|mv .git /tmp/gone
m|none|mkdir -p .agents/specs/active
m|none|mkdir -p .agents/learnings
m|none|rm .agents/specs/active/WORK-9.md
m|none|rm -rf dist/*
m|none|rm -rf .github/workflows/*.tmp
m|none|curl -o out.json https://x.example/y
m|none|curl -O https://x.example/file.tgz
m|none|wget -O - https://x.example/y
m|none|tar -xf a.tar -C build
m|none|unzip a.zip -d build
m|none|cp x build/out
m|none|git checkout HEAD -- src/app.ts
m|none|git restore src/app.ts
m|none|git apply <<'EOF'\n--- a/src/app.ts\n+++ b/src/app.ts\nEOF
CASES

# M4: the current branch is looked up whenever the parser finds a push, however it is spelled.
expect_equal "push on main spelled with quotes asks" ask "$(guard_decision "git p''ush" "$main_repository")"
expect_equal "plain push on main asks" ask "$(guard_decision "git push" "$main_repository")"
expect_equal "quoted push on a feature branch gives no decision" none "$(guard_decision "git p''ush origin feature" "$feature_repository")"
expect_equal "push through an alias on main asks" ask "$(guard_decision "git -c alias.p=push p origin" "$main_repository")"
expect_equal "split word and a non-push command on main give no decision" none "$(guard_decision "git st''atus" "$main_repository")"

# Case-insensitive store paths through Write/Edit/NotebookEdit; Git's own files for subagents.
while IFS='|' read -r expected agent target; do
  [ -n "$expected" ] || continue
  expect_equal "guard-writes fix round: $agent -> $target" "$expected" "$(decision_of "$(write_input "$agent" "$target" "$state_repository" | "$scripts/guard-writes.sh")")"
done <<CASES
deny||$state_repository/.agents/specs/active/WORK-9.STATE.JSON
deny||$state_repository/.AGENTS/SPECS/active/WORK-9.state.json
deny||.Agents/Specs/Active/WORK-9.State.Json
deny||$state_repository/.git/AI-Engineering/Tokens/t
deny|ai-engineering:backend|$state_repository/.git/AI-ENGINEERING/TOKENS/t
deny|ai-engineering:backend|$state_repository/.git/hooks/pre-commit
deny|ai-engineering:frontend|$state_repository/.git/config
deny|ai-engineering:platform|.git/info/exclude
deny|ai-engineering:qa|$state_repository/.git/hooks
deny|ai-engineering:learning|$state_repository/.git/hooks/pre-push
none||$state_repository/.git/hooks/pre-commit
none||$state_repository/.git/info/exclude
none|ai-engineering:backend|$state_repository/.gitignore
none|ai-engineering:backend|$state_repository/src/hooks/pre-commit.ts
CASES
notebook_output="$(jq -n --arg path "$state_repository/.AGENTS/specs/active/WORK-9.STATE.json" --arg cwd "$state_repository" '{agent_type: "ai-engineering:backend", tool_input: {notebook_path: $path}, cwd: $cwd}' | "$scripts/guard-writes.sh")"
expect_equal "guard-writes fix round: NotebookEdit on an upper-case store path" deny "$(decision_of "$notebook_output")"

# L2: the parser budget is counted in bytes. This command is under 262144 characters but over
# 262144 bytes, so it takes the keyword fallback (ask) instead of being parsed (which would deny).
{ printf 'terraform apply && npm publish # '; yes 'ééééééééééééééééééééééééééééééé' | head -n 4500 | tr -d '\n'; } >"$work_directory/multibyte.txt"
jq -n --rawfile command "$work_directory/multibyte.txt" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/multibyte.json"
multibyte_characters="$(jq -r '.tool_input.command | length' "$work_directory/multibyte.json")"
multibyte_bytes="$(jq -r '.tool_input.command | utf8bytelength' "$work_directory/multibyte.json")"
if [ "$multibyte_characters" -lt 262144 ] && [ "$multibyte_bytes" -gt 262144 ]; then pass; else fail "L2 fixture: $multibyte_characters characters, $multibyte_bytes bytes"; fi
expect_equal "guard-bash: over the byte budget (under the character budget) takes the fallback and asks" ask "$(decision_of "$("$scripts/guard-bash.sh" <"$work_directory/multibyte.json")")"

# L1: the guard log is never written through a symbolic link, and rotation takes a lock.
link_repository="$(new_repository link-log-repo feature)"
mkdir -p "$work_directory/link-target"
ln -s "$work_directory/link-target" "$link_repository/.git/ai-engineering"
output="$(agent_output 'cd infra && terraform apply' "$link_repository" b)"
expect_equal "guard log: a symlinked log directory still asks" ask "$(decision_of "$output")"
if [ -e "$work_directory/link-target/guard-log.jsonl" ]; then fail "guard log: wrote through a symlinked directory"; else pass; fi
file_link_repository="$(new_repository link-file-repo feature)"
mkdir -p "$file_link_repository/.git/ai-engineering"
: >"$work_directory/link-file-target"
ln -s "$work_directory/link-file-target" "$file_link_repository/.git/ai-engineering/guard-log.jsonl"
output="$(agent_output 'cd infra && terraform apply' "$file_link_repository" b)"
expect_equal "guard log: a symlinked log file still asks" ask "$(decision_of "$output")"
if [ -s "$work_directory/link-file-target" ]; then fail "guard log: wrote through a symlinked file"; else pass; fi
rotate_repository="$(new_repository rotate-repo feature)"
rotate_directory="$rotate_repository/.git/ai-engineering"
mkdir -p "$rotate_directory"
head -c 1100000 /dev/zero | tr '\0' 'x' >"$rotate_directory/guard-log.jsonl"
mkdir "$rotate_directory/.rotate.lock"
agent_output 'cd infra && terraform apply' "$rotate_repository" b >/dev/null
if [ ! -e "$rotate_directory/guard-log.jsonl.1" ]; then pass; else fail "guard log: rotated while another hook held the lock"; fi
expect_equal "guard log: the decision is still logged while the lock is held" 1 "$(grep -c '"decision"' "$rotate_directory/guard-log.jsonl")"
touch -t 202001010000 "$rotate_directory/.rotate.lock"
agent_output 'cd infra && terraform apply' "$rotate_repository" b >/dev/null
if [ -e "$rotate_directory/guard-log.jsonl.1" ] && [ ! -d "$rotate_directory/.rotate.lock" ]; then pass; else fail "guard log: a stale lock was not cleared and released"; fi

# lib.sh sees the same classification (a representative subset of the fix round).
# (risky_repository is created again, as a fresh repository, in the run-gate section below.)
risky_repository="$feature_repository"
(
  # shellcheck source=../plugins/ai-engineering/scripts/lib.sh
  source "$scripts/lib.sh"
  classify_command_impact "watch terraform apply" "$risky_repository"; [ "$impact_decision" = "ask" ] && [ "$impact_classes" = "infrastructure-apply" ] || exit 1
  classify_command_impact "TERRAFORM apply" "$risky_repository"; [ "$impact_decision" = "ask" ] || exit 2
  classify_command_impact "export X=\$(rm -rf y); terraform apply" "$risky_repository"; [ "$impact_decision" = "deny" ] || exit 3
  classify_command_impact "git \$(echo push) --force origin feature" "$risky_repository"; [ "$impact_decision" = "ask" ] || exit 4
  classify_command_impact "echo 'terraform apply' | bash -" "$risky_repository"; [ "$impact_decision" = "ask" ] || exit 5
  classify_command_impact "echo x > .agents/specs/active/WORK-9.STATE.JSON" "$risky_repository"; [ "$impact_decision" = "deny" ] && [ "$impact_classes" = "authority-store-write" ] || exit 6
  classify_command_impact "git status" "$risky_repository"; [ "$impact_decision" = "none" ] || exit 7
  classify_command_impact "docker exec db psql -c 'DROP TABLE x'" "$risky_repository"; [ "$impact_decision" = "ask" ] || exit 8
)
expect_equal "lib: classify_command_impact sees the fix-round classifications (exit code identifies the failed check)" 0 "$?"

# ---------------------------------------------------------------- WORK-001 fix round 2 (re-review N1-N6)
# Safety floor by construction: the v0.2 keyword rules run over the whole command minus proven
# data spans (guard/tables.jq), so classification can raise a decision but never drop it below
# ask. Table cases are "agent|expected|command" (agent letters as above); "\n" is a newline.
# Every probe of the re-review (rereview-probes.jsonl) except the two N6 owner-ruling cases:
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "fix round 2 re-review ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
m|ask|alias terraform=terraform; terraform apply
m|ask|terraform apply; alias terraform=x
m|ask|alias x='terraform apply'; x
m|ask|git submodule foreach 'terraform apply'
m|ask|git rebase -x 'terraform apply' HEAD~1
m|ask|git bisect run terraform apply
m|ask|git difftool -x 'terraform apply'
m|ask|git filter-branch --tree-filter 'terraform apply'
m|ask|git grep -O'terraform apply' x
m|ask|git fetch --upload-pack='terraform apply; git-upload-pack' .
m|ask|git -c core.pager='terraform apply' -p log
b|deny|git fetch --upload-pack='sh -c x' .
b|deny|git grep -Ofoo x
b|deny|git -c include.path=/tmp/x diff
b|deny|git -c diff.x.textconv=foo show
b|deny|git -c protocol.ext.allow=always fetch ext::foo
b|deny|git -c gpg.ssh.program=foo log --show-signature
b|deny|git -c uploadpack.packObjectsHook=foo fetch .
m|ask|awk 'BEGIN{system("terraform apply")}'
m|ask|sed 'e terraform apply' f
m|ask|tar -xf a.tar --to-command='terraform apply'
m|ask|zip -T -TT 'terraform apply' z.zip f
m|ask|echo 'terraform apply' | xargs -0 sh -c
m|ask|printf '%s' 'terraform apply' | xargs -I{} bash -c '{}'
m|ask|kubectl run t --image=x --rm -i -- terraform apply
m|ask|make --eval='x: ; terraform apply' x
m|ask|gcloud compute ssh vm --command='terraform apply'
m|deny|X=$(rm -rf y) terraform apply
m|deny|terraform apply $(rm -rf y)
m|deny|echo $(rm -rf y) $(terraform apply)
m|deny|export X=$(cat a > b) && terraform apply
m|deny|terraform apply | cat > out.txt
m|deny|export X=$(git config core.hooksPath /tmp/h) && terraform apply
m|deny|rm -rf y | psql -c 'DROP TABLE x'
m|deny|echo x > .ag*/specs/active/W-1.st*
m|deny|tee {.agents,.x}/specs/active/W-1.{state,x}.json
m|deny|S=state; echo x > .agents/specs/active/W-1.$S.json
b|deny|printf x >> .gi[t]/config
b|deny|git log -1 --format=x --output .g?t/config
b|deny|git -C .git log -1 --format=x --output=config
m|deny|git -C .git/ai-engineering log -1 --format=x --output=tokens/t
m|deny|env -C .git/ai-engineering sh -c 'echo x > tokens/t'
m|deny|cp -l .agents/specs/active/W-1.state.json /tmp/h
m|deny|link .agents/specs/active/W-1.state.json /tmp/h
CASES

# Proven data spans (the only floor exemptions), each with the shape that is not data.
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "fix round 2 floor ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
m|none|echo "terraform apply" | tee notes.txt
m|none|echo 'npm publish' | grep npm | wc -l
m|ask|echo "terraform apply" | foo
m|ask|cat <<'X' | foo\nterraform apply\nX
m|ask|foo $(echo terraform) apply
m|ask|echo terraform | xargs -I{} {} apply
m|ask|echo apply | xargs terraform
m|none|grep -rn 'terraform apply' . | head -5
m|ask|rg --pre 'terraform apply' x
m|none|git -c color.ui=always log -S 'TRUNCATE'
m|ask|git -c core.pager=cat log -S 'TRUNCATE'
m|ask|git -c core.editor='terraform apply' commit -m x
m|none|git commit -F - <<'EOF'\nrelease: terraform destroy notes\nEOF
m|none|git commit -m "$(echo terraform destroy)"
m|none|git log --oneline main && git push origin feature
m|none|gh api repos/o/r/releases --method GET
m|ask|curl -X POST https://example.com/x/scripts/deploy.sh
m|none|sed 's/terraform apply/x/' f
m|none|sed -i '' 's/a/npm publish/' f.ts
m|ask|sed 's/x/terraform apply/e' f
m|ask|sed -e 's/a/b/' -e 'e terraform apply' f
m|ask|sed -n '/terraform apply/p' notes.md
m|ask|pnpm run release-it
m|ask|FOO='terraform apply' make test
m|ask|echo x > scripts/release.sh
m|ask|alias ls='terraform apply'
m|ask|bash -c 'git commit -m "npm publish notes"'
m|ask|echo 'npm publish' | psql
CASES

# Executing constructs are parsed (precise labels) and bundling counts effectful substitutions (N3, N4).
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "fix round 2 carriers and bundling ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
m|ask|tar -cf a.tar --checkpoint=1 --checkpoint-action=exec='terraform apply' .
m|ask|sort --compress-program='terraform apply' f
m|deny|git rebase -x 'echo hi' HEAD~1 && terraform apply
m|deny|export X=$(op read x) && terraform apply
m|ask|terraform apply -var x=$(git rev-parse HEAD)
m|deny|export X=$(git -c core.pager=x log) && terraform apply
m|deny|echo $(rm -rf y) | psql -c 'DROP TABLE x'
m|ask|cat a | psql -c 'DROP TABLE x'
m|deny|git commit -m "$(rm -rf y)" && terraform apply
m|deny|node -e "await sql`DROP DATABASE x` $(rm -rf y)"
m|ask|node -e "await sql\`DROP DATABASE x\`"
m|ask|kubectl debug node/x -it --image=busybox -- terraform apply
m|none|kubectl run t --image=x
CASES
reason="$(guard_reason "git submodule foreach 'terraform apply'")"
expect_contains "fix round 2: an executing construct is labelled precisely" "terraform apply [infrastructure-apply]" "$reason"
reason="$(guard_reason "sed 'e terraform apply' f")"
expect_contains "fix round 2: a floor-only ask names the floor and the class" "not proven to be data (class: infrastructure-apply)" "$reason"
expect_contains "fix round 2: a floor-only ask keeps the guardrail note" "Hooks are guardrails, not a sandbox." "$reason"

# Paths and Git by subagents (N2, N5).
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "fix round 2 paths and Git ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
m|none|echo x > "$HOME/.gitconfig"
m|none|echo x > "$TMPDIR/out.json"
m|none|rm -rf */*
m|none|rm -rf build/*/cache
m|deny|rm -rf .git/ai-engineering/tok*
m|deny|sudo -D .git/ai-engineering sh -c 'echo x > tokens/t'
m|deny|env --chdir=.agents/specs/active touch W-1.state.json
m|deny|cp --link .agents/specs/active/W-1.state.json /tmp/h
m|deny|ln .agents/specs/active/W-1.state.json /tmp/h
m|none|cp .agents/specs/active/W-1.state.json /tmp/h
m|none|echo x > docs/notes.md
b|none|git log -Oorder.txt
b|none|git -c color.ui=always status
b|none|git -c core.quotepath=false status
b|deny|git -c core.pager=cat log
b|deny|git log --ext-diff
b|deny|git diff --textconv
b|deny|git --config-env=core.pager=X log
b|none|git fetch origin
b|deny|git fetch --receive-pack=x origin
CASES
# N6 owner ruling: whole-tree writers ask (protected-tree-overwrite) when the destination is the
# repository root, an ancestor of it, inside .git or .agents/specs, or cannot be resolved; no
# decision when it cannot contain a protected path; existing denies win. Each form runs for the
# main session (m) and a specialist (b); "agent|expected|command", the agent repository is the cwd.
# Changed by Option B (2026-10-12), none -> ask: `git checkout -- .`, `git restore .` and
# `git reset --hard` (no hook-time state check any more, so a whole-tree discard asks).
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "fix round 2 N6 ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
m|ask|cp -R /tmp/src/. .
b|ask|cp -R /tmp/src/. .
m|ask|cp -a /tmp/src/. ..
b|ask|cp -a /tmp/src/. ..
m|ask|cp -r /tmp/src .git/hooks
m|none|cp -R src/ build/
b|none|cp -R src/ build/
m|none|cp -a src/. dist
m|ask|rsync -a /tmp/src/ ./
b|ask|rsync -a /tmp/src/ ./
m|deny|rsync -r x/ .agents/specs/
m|ask|rsync -r x/ .git/info/
m|none|rsync -a x/ dist/
b|none|rsync -a x/ dist/
m|ask|tar -xf a.tar
b|ask|tar -xf a.tar
m|ask|tar -xzf a.tgz -C ..
m|ask|tar xf a.tar -C .
m|ask|bsdtar -xf a.tar
m|none|tar -xf a.tar -C vendor/
b|none|tar -xf a.tar -C vendor/
m|none|tar -tf a.tar
m|ask|unzip a.zip
b|ask|unzip a.zip
m|none|unzip a.zip -d vendor
b|none|unzip a.zip -d vendor
m|none|unzip -l a.zip
m|ask|ditto /tmp/src .
b|ask|ditto /tmp/src .
m|none|ditto /tmp/src build/out
b|none|ditto /tmp/src build/out
m|ask|cpio -idm < a.cpio
b|ask|cpio -idm < a.cpio
m|none|cpio -idm -D vendor < a.cpio
m|none|cpio -o < list > a.cpio
m|ask|pax -r < a.pax
m|none|pax -rw src build
m|ask|7z x a.7z
m|none|7z x a.7z -obuild
m|ask|git checkout main -- .
b|deny|git checkout main -- .
m|ask|git restore --source HEAD~1 .
b|deny|git restore --source HEAD~1 .
m|ask|git restore -s HEAD~1 -- ..
m|ask|git reset --hard HEAD~1
b|deny|git reset --hard HEAD~1
m|ask|git read-tree -u --reset HEAD~1
m|ask|git checkout -- .
m|ask|git restore .
m|ask|git reset --hard
m|none|git checkout main -- src/app.ts
m|none|git restore --source HEAD~1 src
m|none|git restore --staged --source HEAD~1 .
m|ask|cp -R "$SRC"/. .
b|ask|cp -R "$SRC"/. .
m|ask|tar -xf "$ARCHIVE"
m|ask|cp -R x "$DEST"
m|ask|cp -R /tmp/src/* .
m|ask|git checkout "$REF" -- .
m|ask|sudo cp -R /tmp/src/. .
m|ask|bash -c 'tar -xf a.tar'
m|ask|env -C .. tar -xf a.tar
m|deny|cp -r x .git/ai-engineering
m|deny|tar -xf a.tar -C .agents/specs/active
b|deny|tar -xf a.tar -C .git/hooks
m|deny|cp -R /tmp/src/. . && rm .agents/specs/active/WORK-9.state.json
CASES
reason="$(agent_output 'cp -R /tmp/src/. .' "$agent_repository" m | jq -r '.hookSpecificOutput.permissionDecisionReason')"
expect_contains "fix round 2 N6: the ask names the operation" "cp (recursive) into ." "$reason"
expect_contains "fix round 2 N6: the ask names the protected path it can reach" "the repository root" "$reason"
expect_contains "fix round 2 N6: the ask keeps the guardrail note" "Hooks are guardrails, not a sandbox." "$reason"
(
  # shellcheck source=../plugins/ai-engineering/scripts/lib.sh
  source "$scripts/lib.sh"
  classify_command_impact "git checkout main -- ." "$agent_repository"; [ "$impact_decision" = "ask" ] && [ "$impact_classes" = "protected-tree-overwrite" ] || exit 1
  classify_command_impact "tar -xf a.tar -C vendor/" "$agent_repository"; [ "$impact_decision" = "none" ] || exit 2
)
expect_equal "lib: classify_command_impact labels whole-tree writers (exit code identifies the failed check)" 0 "$?"
# From a subdirectory the repository root is looked up: extracting into the subdirectory is not
# a protected ancestor, extracting into its parent (the root) is.
expect_equal "fix round 2 N6: extraction into a subdirectory is no decision" none "$(decision_of "$(agent_output 'tar -xf a.tar' "$agent_repository/src" m)")"
expect_equal "fix round 2 N6: extraction into the root from a subdirectory asks" ask "$(decision_of "$(agent_output 'tar -xf a.tar -C ..' "$agent_repository/src" m)")"

long_s="$(printf '\xc5\xbf')"
expect_equal "fix round 2: a long-s look-alike store target denies (Bash)" deny "$(decision_of "$(agent_output "echo x > .agents/specs/active/WORK-9.${long_s}tate.json" "$agent_repository" m)")"
expect_equal "fix round 2: non-ASCII outside the store is no decision (Bash)" none "$(decision_of "$(agent_output "echo x > docs/caf$(printf '\xc3\xa9').md" "$agent_repository" m)")"

# Floor property: every v0.2 ask case still asks when an inert-looking runner carries it: awk
# system(), an alias that shadows its program, and a Git pager.
while IFS= read -r command_text; do
  [ -n "$command_text" ] || continue
  awk_text="${command_text//\\/\\\\}"
  awk_text="${awk_text//\"/\\\"}"
  first_word="$(printf '%s\n' "$command_text" | tr ' ' '\n' | grep -v '=' | head -n 1)"
  expect_equal "floor property (awk system): $command_text" ask "$(guard_decision "awk 'BEGIN{system(\"$awk_text\")}'")"
  expect_equal "floor property (alias shadow): $command_text" ask "$(guard_decision "alias $first_word=true; $command_text")"
  expect_equal "floor property (git pager): $command_text" ask "$(guard_decision "git -c core.pager='$command_text' -p log")"
done <<'CASES'
terraform apply
terraform -chdir=infra apply -auto-approve
tofu destroy
terragrunt run-all apply
FOO=1 terraform apply
bash -c "terraform apply"
pulumi up --yes
npx cdk deploy MyStack
cdk destroy
kubectl delete pod web-1
sudo kubectl -n prod delete deployment api
helm uninstall api
aws s3 rm s3://bucket/key
aws s3 rb s3://bucket --force
aws ec2 terminate-instances --instance-ids i-123
aws s3 sync . s3://bucket --delete
gcloud compute instances delete vm-1
az group delete -n rg
psql -c "DROP TABLE users"
mysql -e "drop database app"
psql -c "TRUNCATE orders"
git push --force origin feature
git push -f origin feature
git push --force-with-lease origin feature
git push origin +feature
git push origin --delete feature
git push origin :feature
git push origin main
git push origin HEAD:master
git push --tags
gh pr merge 12 --squash
gh release create v1.0.0
npm publish
pnpm publish --access public
yarn npm publish
cargo publish
twine upload dist/*
docker push org/image:1
npm run deploy:prod
make deploy
./scripts/release.sh
CASES

# The floor text over its jq budget (16 KB) is scanned by the wrapper (linear grep), never skipped.
{ printf 'foo'; i=0; while [ "$i" -lt 2500 ]; do printf ' word%s' "$i"; i=$((i + 1)); done; printf ' terraform apply\n'; } >"$work_directory/floor-large.txt"
jq -n --rawfile command "$work_directory/floor-large.txt" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/floor-large.json"
expect_equal "fix round 2: a large floor text with a reserved keyword asks" ask "$(decision_of "$("$scripts/guard-bash.sh" <"$work_directory/floor-large.json")")"
sed 's/ terraform apply$/ terraform plan/' "$work_directory/floor-large.txt" >"$work_directory/floor-large-harmless.txt"
jq -n --rawfile command "$work_directory/floor-large-harmless.txt" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/floor-large-harmless.json"
expect_equal "fix round 2: a large harmless floor text is no decision" none "$(decision_of "$("$scripts/guard-bash.sh" <"$work_directory/floor-large-harmless.json")")"
floor_large_ms="$(elapsed_milliseconds "$work_directory/floor-large.json")"
if [ "$floor_large_ms" -lt 2500 ]; then pass; else fail "performance: large floor text took ${floor_large_ms} ms"; fi

# lib.sh sees the fix-round-2 classifications.
(
  # shellcheck source=../plugins/ai-engineering/scripts/lib.sh
  source "$scripts/lib.sh"
  classify_command_impact "awk 'BEGIN{system(\"terraform apply\")}'" "$agent_repository"; [ "$impact_decision" = "ask" ] || exit 1
  classify_command_impact "git -c core.pager='terraform apply' -p log" "$agent_repository"; [ "$impact_decision" = "ask" ] || exit 2
  classify_command_impact "alias terraform=terraform; terraform apply" "$agent_repository"; [ "$impact_decision" = "ask" ] || exit 3
  classify_command_impact "X=\$(rm -rf y) terraform apply" "$agent_repository"; [ "$impact_decision" = "deny" ] || exit 4
  classify_command_impact "echo x > .ag*/specs/active/W-1.st*" "$agent_repository"; [ "$impact_decision" = "deny" ] && [ "$impact_classes" = "authority-store-write" ] || exit 5
  classify_command_impact "sed 'e terraform apply' f" "$agent_repository"; [ "$impact_decision" = "ask" ] && [ "$impact_classes" = "infrastructure-apply" ] || exit 6
  classify_command_impact "rg 'terraform apply' docs/" "$agent_repository"; [ "$impact_decision" = "none" ] || exit 7
  classify_command_impact "$(cat "$work_directory/floor-large.txt")" "$agent_repository"; [ "$impact_decision" = "ask" ] || exit 8
)
expect_equal "lib: classify_command_impact sees the fix-round-2 classifications (exit code identifies the failed check)" 0 "$?"

# N6: log rotation never follows a planted guard-log.jsonl.1 (a link to a file or a directory).
for planted in file directory; do
  planted_repository="$(new_repository "planted-$planted-repo" feature)"
  planted_directory="$planted_repository/.git/ai-engineering"
  mkdir -p "$planted_directory" "$work_directory/planted-$planted-target"
  printf 'keep\n' >"$work_directory/planted-$planted-target/content"
  head -c 1100000 /dev/zero | tr '\0' 'x' >"$planted_directory/guard-log.jsonl"
  if [ "$planted" = file ]; then
    ln -s "$work_directory/planted-$planted-target/content" "$planted_directory/guard-log.jsonl.1"
  else
    ln -s "$work_directory/planted-$planted-target" "$planted_directory/guard-log.jsonl.1"
  fi
  output="$(agent_output 'cd infra && terraform apply' "$planted_repository" b)"
  expect_equal "guard log: a planted $planted link as the rotated log still asks" ask "$(decision_of "$output")"
  expect_equal "guard log: the planted $planted link target is unchanged" "content" "$(ls "$work_directory/planted-$planted-target")"
  expect_equal "guard log: the planted $planted link target content is unchanged" keep "$(cat "$work_directory/planted-$planted-target/content")"
  if [ -L "$planted_directory/guard-log.jsonl.1" ]; then fail "guard log: the planted $planted link was kept as the rotated log"; else pass; fi
done
blocked_rotation_repository="$(new_repository blocked-rotation-repo feature)"
mkdir -p "$blocked_rotation_repository/.git/ai-engineering/guard-log.jsonl.1"
head -c 2200000 /dev/zero | tr '\0' 'x' >"$blocked_rotation_repository/.git/ai-engineering/guard-log.jsonl"
output="$(agent_output 'cd infra && terraform apply' "$blocked_rotation_repository" b)"
expect_equal "guard log: a directory in the rotation slot still asks" ask "$(decision_of "$output")"
expect_equal "guard log: a directory in the rotation slot keeps the log bounded" 2200000 "$(wc -c <"$blocked_rotation_repository/.git/ai-engineering/guard-log.jsonl" | tr -d ' ')"

# N5: a Write/Edit to a hard link of a store file is denied; a hard link to another file is not.
ln "$state_repository/.agents/specs/active/WORK-9.state.json" "$state_repository/hard-link-state.json"
printf 'x\n' >"$state_repository/plain-original.txt"
ln "$state_repository/plain-original.txt" "$state_repository/plain-link.txt"
expect_equal "guard-writes: a hard link to a store file is denied" deny "$(decision_of "$(write_input "" "$state_repository/hard-link-state.json" "$state_repository" | "$scripts/guard-writes.sh")")"
expect_equal "guard-writes: a hard link to a store file is denied for subagents" deny "$(decision_of "$(write_input ai-engineering:backend "hard-link-state.json" "$state_repository" | "$scripts/guard-writes.sh")")"
expect_equal "guard-writes: a hard link to an ordinary file is no decision" none "$(decision_of "$(write_input "" "$state_repository/plain-link.txt" "$state_repository" | "$scripts/guard-writes.sh")")"
rm -f "$state_repository/hard-link-state.json" "$state_repository/plain-link.txt" "$state_repository/plain-original.txt"

# N6: on macOS (APFS) check whether a long-s look-alike opens the store file, and that Write/Edit
# and Bash deny such paths on every platform.
long_s_state="$state_repository/.agents/specs/active/WORK-9.${long_s}tate.json"
if [ "$(uname -s)" = Darwin ]; then
  if [ -e "$long_s_state" ]; then
    echo "info: APFS check: a long-s (U+017F) look-alike path opens the store file (case folding)"
  else
    echo "info: APFS check: a long-s (U+017F) look-alike path does not open the store file on this volume"
  fi
fi
expect_equal "guard-writes: a long-s look-alike store path is denied" deny "$(decision_of "$(write_input "" "$long_s_state" "$state_repository" | "$scripts/guard-writes.sh")")"
expect_equal "guard-writes: a Kelvin-sign look-alike token path is denied" deny "$(decision_of "$(write_input "" "$state_repository/.git/ai-engineering/to$(printf '\xe2\x84\xaa')ens/t" "$state_repository" | "$scripts/guard-writes.sh")")"
expect_equal "guard-writes: a long-s look-alike Git hooks directory is denied for subagents" deny "$(decision_of "$(write_input ai-engineering:backend "$state_repository/.git/hook$(printf '\xc5\xbf')/pre-commit" "$state_repository" | "$scripts/guard-writes.sh")")"
expect_equal "guard-writes: a non-ASCII name outside the store is no decision" none "$(decision_of "$(write_input "" "$state_repository/src/caf$(printf '\xc3\xa9').ts" "$state_repository" | "$scripts/guard-writes.sh")")"
expect_equal "guard-writes: a non-ASCII learning file inside .agents is allowed" none "$(decision_of "$(write_input ai-engineering:learning "$state_repository/.agents/learnings/caf$(printf '\xc3\xa9').md" "$state_repository" | "$scripts/guard-writes.sh")")"

# ---------------------------------------------------------------- WORK-001 fix round 3 (re-review 2 NR-1 to NR-5, H5)
# Table cases are "agent|expected|command" (agents as above); "\n" is a newline. Characters a
# heredoc cannot hold are written as @NAME@ and expanded by expand_characters.
carriage_return=$'\r' form_feed=$'\f' vertical_tab=$'\v'
no_break_space="$(printf '\xc2\xa0')" em_space="$(printf '\xe2\x80\x83')" ideographic_space="$(printf '\xe3\x80\x80')"
zero_width_space="$(printf '\xe2\x80\x8b')" kelvin_sign="$(printf '\xe2\x84\xaa')" st_ligature="$(printf '\xef\xac\x86')" e_acute="$(printf '\xc3\xa9')"
expand_characters() {
  local text="$1"
  text="${text//@CR@/$carriage_return}"; text="${text//@FF@/$form_feed}"; text="${text//@VT@/$vertical_tab}"
  text="${text//@NBSP@/$no_break_space}"; text="${text//@EMSP@/$em_space}"; text="${text//@IDSP@/$ideographic_space}"
  text="${text//@ZWSP@/$zero_width_space}"; text="${text//@KELVIN@/$kelvin_sign}"; text="${text//@LONGS@/$long_s}"
  text="${text//@ST@/$st_ligature}"; text="${text//@EACUTE@/$e_acute}"; text="${text//@TAB@/$'\t'}"
  printf '%s' "$text"
}
# Every probe of re-review 2 (rereview2-probes.jsonl) except the five N6 boundary cases (owner
# decision pending), then the fix-round-3 variants. Write-then-run denies: the writer is another
# command, as for the existing `cat > f.sh <<EOF ... EOF; bash f.sh` case (the brief allows ask or deny).
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  command_text="$(expand_characters "$command_text")"
  expect_equal "fix round 3 ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
m|ask|echo a@CR@#; terraform apply
m|ask|echo a@NBSP@#; terraform apply
m|ask|echo a@VT@#; terraform apply
m|ask|@KELVIN@ubectl delete pod x
m|ask|terraform apply -lock=fal@LONGS@e
m|ask|ku@KELVIN@bectl delete pod x
m|ask|echo 'terraform apply' | tee >(sh)
m|ask|echo 'terraform apply' > >(sh)
m|ask|printf 'terraform apply' | sort -S 1K --compress-program=sh
m|deny|echo 'terraform apply' | tee r.sh; sh ./r.sh
m|deny|echo 'terraform apply' > r && chmod +x r && ./r
m|deny|echo 'terraform apply' | cat > r.sh; bash r.sh
m|deny|git rm .agents/specs/active/WORK-9.state.json
m|deny|git mv .agents/specs/active/WORK-9.state.json x.json
m|ask|git checkout HEAD~1 -- ':/'
m|ask|git checkout HEAD~1 -- ':(top)'
m|ask|git restore --source=HEAD~1 --pathspec-from-file=list.txt
m|ask|git checkout-index -f -a
m|deny|git update-index --cacheinfo 100644,abc,.agents/specs/active/WORK-9.state.json
b|deny|GIT_EXTERNAL_DIFF=x git diff
b|deny|GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=x git log
b|deny|env GIT_PAGER=x git log
m|ask|echo a@FF@#; terraform apply
m|ask|echo a@EMSP@#; terraform apply
m|ask|echo a@IDSP@#; terraform apply
m|ask|echo a@ZWSP@#; terraform apply
m|ask|terraform@NBSP@apply
m|deny|echo a#b; terraform apply
m|none|echo 'a@NBSP@b'
m|none|git commit -m 'note@EMSP@x'
m|ask|mysql -e "SELECT 1 --@NBSP@x; DROP TABLE t"
m|ask|aw@LONGS@ s3 rm s3://b/k
m|ask|git pu@LONGS@h --force origin x
m|ask|docker pu@LONGS@h org/image:1
m|ask|helm unin@ST@all api
m|ask|cargo publi@LONGS@h
m|none|caf@EACUTE@ x
m|none|echo caf@EACUTE@
m|ask|echo 'terraform apply' | tee >(bash)
m|ask|printf 'DROP TABLE x' | tee >(psql)
m|ask|echo 'terraform apply' | tee >(cat) out.txt
m|deny|tee >(echo 'terraform apply' | sh) < notes.txt
m|none|diff <(sort a) <(sort b)
m|ask|echo 'terraform apply' | rg --pre=sh x
m|ask|echo 'terraform apply' | less '+!sh'
m|none|echo 'terraform apply' | sort
m|deny|echo 'terraform apply' > r.sh; source r.sh
m|deny|echo 'terraform apply' > r.sh; . ./r.sh
m|deny|cd sub && echo 'terraform apply' > r.sh && cd .. && sh sub/r.sh
m|ask|echo 'terraform apply' > notes.txt; ./build.sh
m|ask|echo 'terraform apply' > "$F"; sh "$F"
m|ask|bash -c "echo 'terraform apply' > r.sh"; sh r.sh
m|ask|python3 -c "open('r.sh','w').write('terraform apply')"; sh r.sh
m|none|echo hi > notes.txt; ./build.sh
m|deny|git mv x.json .agents/specs/active/WORK-9.state.json
m|deny|git rm --cached .agents/specs/active/WORK-9.state.json
m|ask|git rm -r .
m|ask|git rm ':(glob)**/*.json'
m|none|git rm src/app.ts
m|ask|git checkout HEAD~1 -- ':!src'
m|deny|git checkout HEAD~1 -- ':(icase).AGENTS/specs/active/W.state.json'
m|ask|git restore --source=HEAD~1 ':/'
m|ask|git reset HEAD~1 -- ':/'
m|ask|git checkout HEAD~1 --pathspec-from-file=list.txt
m|ask|git clean -fdx
m|ask|git clean -fX
m|none|git clean -fd src
m|none|git clean -n -dx
m|deny|git update-index --cacheinfo 100644 abc .agents/specs/active/WORK-9.state.json
m|ask|git update-index --index-info
m|none|git update-index --add src/app.ts
m|deny|git checkout-index -f .agents/specs/active/WORK-9.state.json
m|none|git checkout-index --prefix=build/ -a
m|ask|git read-tree HEAD~1
m|deny|git read-tree --prefix=.agents/specs/ HEAD
m|deny|git hash-object -w --path=.agents/specs/active/WORK-9.state.json x
m|ask|git hash-object -w --stdin-paths
b|deny|GIT_SSH_COMMAND='ssh -i k' git fetch
b|deny|export GIT_PAGER=x; git log
b|deny|declare -x GIT_CONFIG_GLOBAL=/tmp/c; git log
b|deny|PAGER=less git log
b|deny|GIT_TERMINAL_PROMPT=1 git fetch
b|deny|sudo GIT_EDITOR=vim git status
b|none|GIT_PAGER=cat LANG=C git log
b|none|GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 LC_ALL=C git status
b|none|export NODE_ENV=test; git status
m|none|GIT_PAGER=x git log
CASES

# Soft uncertainty (a script whose text is unknown after a write) applies the fallback only when the
# parse reached no decision: its denies stand, and a script with no write around it stays parsed.
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "fix round 3 soft uncertainty ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
m|deny|echo x > .agents/specs/active/WORK-9.state.json; ./build.sh
b|deny|echo x > out.txt; ./build.sh; git commit -m x
m|none|nvm use && "$PLUGIN/scripts/run-gate.sh" fast && git status --short && grep -rn "DROP\|TRUNCATE" src
m|none|./scripts/test.sh && sh ./scripts/lint.sh
m|deny|cat > q.sql <<'EOF'\nDROP TABLE x;\nEOF\npsql -f q.sql
m|none|git rm -n .agents/specs/active/WORK-9.state.json
m|deny|git clean -fd .agents
CASES

# N6(a) owner ruling: branch switches, merge, pull, rebase, cherry-pick, stash and no-ref whole-tree
# restores ask only when the .agents/specs state files can change. Fixture: main holds a state file;
# branch "same" changes only src/a.txt (state identical), branch "differs" changes the state file.
state_fixture="$(new_repository state-fixture-repo main)"
mkdir -p "$state_fixture/.agents/specs/active" "$state_fixture/src"
printf '{"status":"draft"}\n' >"$state_fixture/.agents/specs/active/WORK-1.state.json"
printf 'a\n' >"$state_fixture/src/a.txt"
commit_state_fixture() { git -C "$state_fixture" add -A && git -C "$state_fixture" -c user.name=test -c user.email=test@example.com commit -q -m "$1"; }
commit_state_fixture "state"
git -C "$state_fixture" branch same && git -C "$state_fixture" branch differs
git -C "$state_fixture" checkout -q same && printf 'b\n' >"$state_fixture/src/a.txt" && commit_state_fixture "same state"
git -C "$state_fixture" checkout -q differs && printf '{"status":"approved"}\n' >"$state_fixture/.agents/specs/active/WORK-1.state.json" && commit_state_fixture "state differs"
git -C "$state_fixture" checkout -q main
if [ -f "$state_fixture/.agents/specs/active/WORK-1.state.json" ] && [ "$(git -C "$state_fixture" rev-parse --abbrev-ref HEAD)" = main ] \
  && ! git -C "$state_fixture" diff --quiet main differs -- .agents && git -C "$state_fixture" diff --quiet main same -- .agents; then pass
else fail "fix round 3 N6(a): the state fixture repository is not as intended"; fi
# Clean working tree. Changed expectations (Option B, owner decision 2026-10-12): the guard no
# longer inspects Git state at hook time, so every state-changing form asks, whether or not the
# state differs. Changed none -> ask: the "same" switch, checkout, checkout -b, merge, rebase and
# cherry-pick; stash; checkout -- .; restore .; reset --hard; and `git checkout src/a.txt` (one
# operand may be a branch, which the guard can no longer resolve). The forms that cannot replace
# tracked state files (paths that cannot reach a protected path, -b/-c from HEAD, stash list,
# reset without --hard) stay none: added below.
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "fix round 3 N6(a) clean ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$state_fixture" "$agent")")"
done <<'CASES'
m|ask|git switch same
m|ask|git switch differs
m|ask|git checkout same
m|ask|git checkout differs
m|ask|git checkout -b topic same
m|ask|git switch -c topic differs
m|ask|git merge same
m|ask|git merge differs
m|ask|git rebase same
m|ask|git rebase differs
m|ask|git cherry-pick same
m|ask|git cherry-pick differs
m|ask|git switch missing-branch
m|ask|git switch "$BRANCH"
m|ask|git pull
m|ask|git commit -m x && git switch same
m|ask|git fetch && git merge same
m|ask|git -C . switch same
m|ask|git stash
m|ask|git stash pop
m|ask|git checkout -- .
m|ask|git restore .
m|ask|git reset --hard
m|ask|git checkout src/a.txt
m|none|git checkout -- src/a.txt
m|none|git restore src/a.txt
m|none|git checkout -b topic
m|none|git switch -c topic
m|none|git stash list
m|none|git reset HEAD~1
b|deny|git switch same
CASES
# Uncommitted state changes: operations that discard them ask; ordinary paths and switches do not.
printf '{"status":"edited"}\n' >"$state_fixture/.agents/specs/active/WORK-1.state.json"
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "fix round 3 N6(a) uncommitted state ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$state_fixture" "$agent")")"
done <<'CASES'
m|ask|git stash
m|ask|git checkout -- .
m|ask|git restore .
m|ask|git reset --hard
m|ask|git switch -f same
m|ask|git merge --abort
m|none|git checkout -- src
m|ask|git switch same
CASES
git -C "$state_fixture" checkout -q -- .agents
# Option B: the reason names the operation and says why the guard cannot clear it (it no longer
# compares states, so it cannot name the difference).
reason="$(agent_output 'git switch differs' "$state_fixture" m | jq -r '.hookSpecificOutput.permissionDecisionReason')"
expect_contains "Option B: the ask names the operation" "git switch can replace protected state" "$reason"
expect_contains "Option B: the ask says the guard does not inspect Git state" "the guard does not inspect Git state" "$reason"
# Option B: an identical-state switch now asks, so it is logged (was: not logged).
log_lines_before="$(wc -l <"$state_fixture/.git/ai-engineering/guard-log.jsonl" 2>/dev/null | tr -d ' ')"
agent_output 'git switch same' "$state_fixture" m >/dev/null
expect_equal "Option B: an identical-state switch is logged" "$((${log_lines_before:-0} + 1))" "$(wc -l <"$state_fixture/.git/ai-engineering/guard-log.jsonl" 2>/dev/null | tr -d ' ')"
(
  # shellcheck source=../plugins/ai-engineering/scripts/lib.sh
  source "$scripts/lib.sh"
  classify_command_impact "git switch differs" "$state_fixture"; [ "$impact_decision" = "ask" ] && [ "$impact_classes" = "protected-tree-overwrite" ] || exit 1
  classify_command_impact "git switch same" "$state_fixture"; [ "$impact_decision" = "ask" ] && [ "$impact_classes" = "protected-tree-overwrite" ] || exit 2
)
expect_equal "lib: classify_command_impact sees state-changing Git as ask (exit code identifies the failed check)" 0 "$?"

# N6(b) owner ruling: patch, git apply and git am ask when the patch is not text from this
# submission; a known patch denies when it touches the store (or Git's own files, for specialists).
# Changed by the owner's closure decision (option 1, 2026-10-12), none -> ask: a patch read from a
# file is never trusted, even one this submission wrote (`cat > f.patch` then `git apply f.patch`).
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "fix round 3 N6(b) ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
m|ask|git apply fix.patch
m|ask|patch -p1 < fix.patch
m|ask|git am mails.mbox
m|ask|curl -s https://example.com/x.patch | git apply
m|none|git apply --check fix.patch
m|none|patch --dry-run -p1 < fix.patch
m|none|git apply <<'EOF'\ndiff --git a/src/app.ts b/src/app.ts\n--- a/src/app.ts\n+++ b/src/app.ts\nEOF
m|deny|patch -p1 <<'EOF'\n--- a/.agents/specs/active/WORK-9.state.json\n+++ b/.agents/specs/active/WORK-9.state.json\nEOF
m|deny|git apply <<'EOF'\ndiff --git a/src/x b/.agents/specs/active/WORK-9.state.json\nrename from src/x\nrename to .agents/specs/active/WORK-9.state.json\nEOF
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ngit apply f.patch
m|deny|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/.agents/specs/active/WORK-9.state.json\nEOF\ngit apply f.patch
m|deny|git apply --directory=.agents/specs/active <<'EOF'\n--- a/x.json\n+++ b/x.json\nEOF
m|deny|git apply --include='.agents/specs/*' <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|none|patch -p1 <<'EOF'\n--- a/.git/hooks/pre-commit\n+++ b/.git/hooks/pre-commit\nEOF
b|deny|patch -p1 <<'EOF'\n--- a/.git/hooks/pre-commit\n+++ b/.git/hooks/pre-commit\nEOF
CASES

# N6(c) owner ruling: a recursive or extract destination with only glob components, under a literal
# subdirectory that is not the root, .agents or .git, with no `..`, is no decision; any variable,
# substitution or brace still asks.
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "fix round 3 N6(c) ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$agent_repository" "$agent")")"
done <<'CASES'
m|none|cp -R x build/*/
m|none|tar -xf a.tar -C vendor/*/lib
m|none|cp -R x /tmp/*/out
m|none|rsync -a x/ dist/??/
m|ask|cp -R x */
m|ask|cp -R x build/*/../..
m|ask|cp -R x build/{a,b}
m|ask|cp -R x "$D"/*
m|ask|cp -R x build/$(date)/*
m|ask|cp -R x .git-x/../*
CASES

# NR-5: the branch guess ignores case; a push spelled in mixed case while on main still asks.
expect_equal "fix round 3 NR-5: a mixed-case push while on main asks" ask "$(guard_decision 'Git Push origin feature' "$main_repository")"
expect_equal "fix round 3 NR-5: a mixed-case push on a feature branch is no decision" none "$(guard_decision 'Git Push origin feature')"
# Reasons name what was found.
reason="$(agent_output 'GIT_PAGER=x git log' "$agent_repository" b | jq -r '.hookSpecificOutput.permissionDecisionReason')"
expect_contains "fix round 3 H5: the deny names the variable" "git with GIT_PAGER set" "$reason"
reason="$(agent_output 'git clean -fdx' "$agent_repository" m | jq -r '.hookSpecificOutput.permissionDecisionReason')"
expect_contains "fix round 3 NR-4: the clean ask names the operation" "git clean -x/-X/-d into ." "$reason"
# The floor text over its jq budget is folded by the wrapper too (NR-2): a look-alike verb asks.
{ printf 'foo'; i=0; while [ "$i" -lt 2500 ]; do printf ' word%s' "$i"; i=$((i + 1)); done; printf ' && docker pu%sh org/image:1\n' "$long_s"; } >"$work_directory/floor-large-look-alike.txt"
jq -n --rawfile command "$work_directory/floor-large-look-alike.txt" --arg cwd "$feature_repository" '{tool_input: {command: $command}, cwd: $cwd}' >"$work_directory/floor-large-look-alike.json"
expect_equal "fix round 3: a large floor text with a look-alike keyword asks" ask "$(decision_of "$("$scripts/guard-bash.sh" <"$work_directory/floor-large-look-alike.json")")"
# lib.sh sees the fix-round-3 classifications.
(
  # shellcheck source=../plugins/ai-engineering/scripts/lib.sh
  source "$scripts/lib.sh"
  classify_command_impact "git clean -fdx" "$agent_repository"; [ "$impact_decision" = "ask" ] && [ "$impact_classes" = "protected-tree-overwrite" ] || exit 1
  classify_command_impact "git rm .agents/specs/active/WORK-9.state.json" "$agent_repository"; [ "$impact_decision" = "deny" ] && [ "$impact_classes" = "authority-store-write" ] || exit 2
  classify_command_impact "echo 'terraform apply' | tee >(sh)" "$agent_repository"; [ "$impact_decision" = "ask" ] || exit 3
  classify_command_impact "terraform${no_break_space}apply" "$agent_repository"; [ "$impact_decision" = "ask" ] || exit 4
)
expect_equal "lib: classify_command_impact sees the fix-round-3 classifications (exit code identifies the failed check)" 0 "$?"

# ---------------------------------------------------------------- WORK-001 fix round 4 (re-review 3 RR3-1 to RR3-13)
# Table cases are "agent|expected|command" (agents as above); "\n" is a newline and @NAME@ a
# character expand_characters supplies. First every probe of re-review 3 (rereview3-probes.jsonl),
# in the agent repository (branch feature; `git checkout feature` alone was no decision and asks
# under Option B, which no longer resolves refs at hook time). Two
# probes drop the `\n` of their printf format, which this table would turn into a newline.
fix4_table() {
  local label="$1" directory="$2" agent expected command_text
  while IFS='|' read -r agent expected command_text; do
    [ -n "$expected" ] || continue
    command_text="$(expand_characters "$command_text")"
    expect_equal "fix round 4 $label ($agent): $command_text" "$expected" "$(decision_of "$(agent_output "$command_text" "$directory" "$agent")")"
  done
}
fix4_table probes "$agent_repository" <<'CASES'
m|ask|git pull && X=@NBSP@
m|ask|git pull; X=@CR@
m|ask|git rm -r . && X=@NBSP@
m|ask|cp -r src/. . && X=@NBSP@
m|ask|git apply unknown.patch && X=@NBSP@
m|ask|git checkout no-such-ref && X=@NBSP@
b|deny|git config core.hooksPath h && X=@NBSP@
b|deny|git stash && X=@NBSP@
b|deny|git remote set-url origin x && X=@NBSP@
b|deny|git branch -f main HEAD && X=@NBSP@
m|ask|git cherry-pick -x no-such-ref
m|ask|git cherry-pick -s no-such-ref
m|ask|git revert -s no-such-ref
m|ask|git checkout -m no-such-ref
m|ask|git switch -m no-such-ref
m|ask|git checkout ':/init\nx'
m|ask|printf '%s' 0000000000000000000000000000000000000000 > .git/refs/heads/feature && git checkout feature
m|ask|make sync && git checkout feature
m|ask|git clean -f
m|ask|git clean -f .
m|ask|git stash -u
m|ask|git stash --all
m|ask|tar -xf a.tar -C ~+
m|ask|cp -r src/. ~+
m|ask|git -C ~+ checkout HEAD -- .
m|ask|cd sub && cd - && cp -r src/. .
m|ask|cp -r x ~/*
m|deny|cat > p.diff <<'EOF'\n--- "a/.agents/specs/active/W.state\056json"\n+++ "b/.agents/specs/active/W.state\056json"\n@@ -1 +1 @@\n-a\n+b\nEOF\ngit apply p.diff
m|deny|cat > p.diff <<'EOF'\n*** .agents/specs/active/WORK-9.state.json\n--- other/x\n***************\nEOF\npatch -p0 < p.diff
m|deny|yq -i '.status="approved"' .agents/specs/active/WORK-9.state.json
m|deny|sort -o .agents/specs/active/WORK-9.state.json <<'EOF'\n{}\nEOF
m|deny|uniq in.json .agents/specs/active/WORK-9.state.json
m|deny|xxd -r in.hex .agents/specs/active/WORK-9.state.json
m|deny|ed -s .agents/specs/active/WORK-9.state.json <<'EOF'\n1d\nw\nEOF
b|deny|eval 'export GIT_EXTERNAL_DIFF=./x' && git diff
b|deny|printf 'export GIT_EXTERNAL_DIFF=./x' > e && . ./e && git diff
m|ask|git checkout feature
CASES

# RR3-1 (HIGH, owner ruling: hardened plumbing only). The hooks' Git (guard/hook-git.sh) must never
# run a repository- or environment-controlled program. Fixture: every extension point Git offers is
# configured to touch a marker: fsmonitor, every hook (in .git/hooks and through core.hooksPath), a
# clean and smudge filter and a textconv driver on the state files, and an external diff with
# trustExitCode. The state file is stat-dirty (same content, older modification time), which made
# the earlier `git status` re-hash it through the filter. Each hook-time lookup (the branch, root
# and common-directory lookups, the shell-edit hint, guard-writes.sh) must leave no
# marker and reach the ruled decision.
hostile_repository="$(new_repository hostile-repo main)"
hostile_markers="$work_directory/hostile-markers" hostile_programs="$work_directory/hostile-programs"
mkdir -p "$hostile_markers" "$hostile_programs/hooks" "$hostile_repository/.agents/specs/active" "$hostile_repository/src"
printf '{"status":"draft"}\n' >"$hostile_repository/.agents/specs/active/WORK-1.state.json"
printf 'a\n' >"$hostile_repository/src/a.txt"
commit_hostile_fixture() { git -C "$hostile_repository" add -A && git -C "$hostile_repository" -c user.name=test -c user.email=test@example.com commit -q -m "$1"; }
commit_hostile_fixture state
git -C "$hostile_repository" branch same && git -C "$hostile_repository" branch differs
git -C "$hostile_repository" checkout -q same && printf 'b\n' >"$hostile_repository/src/a.txt" && commit_hostile_fixture "same state"
git -C "$hostile_repository" checkout -q differs && printf '{"status":"approved"}\n' >"$hostile_repository/.agents/specs/active/WORK-1.state.json" && commit_hostile_fixture "state differs"
git -C "$hostile_repository" checkout -q main
# Each program only touches its marker; the filters pass content through, fsmonitor and the external diff fail.
make_marker_program() { printf '#!/bin/sh\ntouch "%s/%s"\n%s\n' "$hostile_markers" "$1" "$2" >"$hostile_programs/$1" && chmod +x "$hostile_programs/$1"; }
make_marker_program fsmonitor 'exit 1'
make_marker_program filter 'cat'
# shellcheck disable=SC2016 # `$1` belongs to the generated program, not to this script
make_marker_program textconv 'cat "$1"'
make_marker_program external-diff 'exit 1'
# shellcheck disable=SC2016 # `$(basename "$0")` belongs to the generated hook, not to this script
printf '#!/bin/sh\ntouch "%s/hook-$(basename "$0")"\n' "$hostile_markers" >"$hostile_programs/hook" && chmod +x "$hostile_programs/hook"
for hook_name in post-index-change post-checkout post-merge post-rewrite reference-transaction pre-commit pre-auto-gc fsmonitor-watchman pre-push; do
  cp "$hostile_programs/hook" "$hostile_repository/.git/hooks/$hook_name"
  cp "$hostile_programs/hook" "$hostile_programs/hooks/$hook_name"
done
git -C "$hostile_repository" config core.fsmonitor "$hostile_programs/fsmonitor"
git -C "$hostile_repository" config filter.mark.clean "$hostile_programs/filter"
git -C "$hostile_repository" config filter.mark.smudge "$hostile_programs/filter"
git -C "$hostile_repository" config diff.conv.textconv "$hostile_programs/textconv"
git -C "$hostile_repository" config diff.external "$hostile_programs/external-diff"
git -C "$hostile_repository" config diff.trustExitCode true
printf '*.json filter=mark diff=conv\n*.txt filter=mark diff=conv\n' >"$hostile_repository/.git/info/attributes"
touch -t 202001010000 "$hostile_repository/.agents/specs/active/WORK-1.state.json"
rm -f "$hostile_markers"/*
# The names of the files in a directory, space-separated (empty when none).
names_in() { local entry names=""; for entry in "$1"/*; do [ -e "$entry" ] && names="$names${entry##*/} "; done; printf '%s' "$names"; }
# The fixture is genuine: Git's own porcelain does run these programs here (checked through a copy
# of the repository, so the fixture itself stays untouched by porcelain).
cp -R "$hostile_repository" "$work_directory/hostile-copy"
git -C "$work_directory/hostile-copy" status --porcelain >/dev/null 2>&1
if [ -e "$hostile_markers/fsmonitor" ] || [ -e "$hostile_markers/filter" ]; then pass; else fail "fix round 4 RR3-1: the hostile fixture does not run its programs under git status ($(names_in "$hostile_markers"))"; fi
rm -rf "$work_directory/hostile-copy"; rm -f "$hostile_markers"/*
hostile_markers_left() { names_in "$hostile_markers"; }
# Runs a table against the hostile repository: the decision, then no marker. Extra arguments are
# NAME=value assignments for the hook's own environment.
hostile_table() {
  local label="$1" agent expected command_text output
  shift
  while IFS='|' read -r agent expected command_text; do
    [ -n "$expected" ] || continue
    command_text="$(expand_characters "$command_text")"
    output="$(agent_input "$command_text" "$hostile_repository" "$agent" | env "$@" "$scripts/guard-bash.sh")"
    expect_equal "fix round 4 RR3-1 $label ($agent): $command_text" "$expected" "$(decision_of "$output")"
    expect_equal "fix round 4 RR3-1 $label: no repository program ran for: $command_text" "" "$(hostile_markers_left)"
    rm -f "$hostile_markers"/*
  done
}
# Option B (2026-10-12): no hook-time state checks, so every state-changing form asks (the "same"
# and whole-tree discard lines were none). The markers still matter: the branch (push), root (cp),
# common-directory (tokens) and tracked-file (hint) lookups run Git in this repository.
hostile_table "plain environment" <<'CASES'
m|ask|git stash
m|ask|git reset --hard
m|ask|git restore .
m|ask|git checkout -- .
m|ask|git checkout -f
m|ask|git switch differs
m|ask|git switch same
m|ask|git merge differs
m|ask|git merge same
m|ask|git cherry-pick differs
m|ask|git cherry-pick same
m|ask|git checkout same
m|ask|git push origin feature
m|ask|git push
m|ask|cp -R vendor/. .
m|deny|echo x > .git/ai-engineering/tokens/t
b|none|echo hi > src/a.txt
b|deny|git stash && X=@NBSP@
CASES
git -C "$hostile_repository" config core.hooksPath "$hostile_programs/hooks"
hostile_table "core.hooksPath" <<'CASES'
m|ask|git stash
m|ask|git switch differs
m|ask|git switch same
m|ask|git push origin feature
CASES
# Injected configuration in the hook's own environment (a committed settings env block): the
# hook's Git runs without it, so it cannot see what the command will see, and asks.
hostile_table "GIT_CONFIG_COUNT" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor "GIT_CONFIG_VALUE_0=$hostile_programs/fsmonitor" <<'CASES'
m|ask|git stash
m|ask|git reset --hard
m|ask|git switch same
m|ask|git cherry-pick same
m|ask|git push origin feature
CASES
hostile_table "GIT_CONFIG_PARAMETERS" "GIT_CONFIG_PARAMETERS='core.fsmonitor=$hostile_programs/fsmonitor' 'diff.external=$hostile_programs/external-diff'" <<'CASES'
m|ask|git restore .
m|ask|git switch same
CASES
hostile_table "GIT_DIR" "GIT_DIR=$hostile_repository/.git" <<'CASES'
m|ask|git switch same
CASES
# GIT_EXTERNAL_DIFF changes no repository or configuration. Option B: the state-changing forms ask
# regardless (the none lines were identical-state checks).
hostile_table "GIT_EXTERNAL_DIFF" "GIT_EXTERNAL_DIFF=$hostile_programs/external-diff" "GIT_PAGER=$hostile_programs/external-diff" <<'CASES'
m|ask|git stash
m|ask|git checkout -- .
m|ask|git switch same
m|ask|git switch differs
m|ask|git cherry-pick same
m|ask|git cherry-pick differs
m|ask|git push origin feature
CASES
# guard-writes.sh: its common-directory and top-level lookups use the same interface. NF-3 (Option
# B round): a token-store-like path outside .git, judged under injected Git configuration in the
# hook environment, asks (was none: the lookup ignored the environment the write would see).
while IFS='|' read -r expected agent target; do
  [ -n "$expected" ] || continue
  output="$(write_input "$agent" "$target" "$hostile_repository" | env "GIT_CONFIG_PARAMETERS='core.fsmonitor=$hostile_programs/fsmonitor'" "$scripts/guard-writes.sh")"
  expect_equal "fix round 4 RR3-1 guard-writes: $agent -> $target" "$expected" "$(decision_of "$output")"
  expect_equal "fix round 4 RR3-1 guard-writes: no repository program ran for: $target" "" "$(hostile_markers_left)"
  rm -f "$hostile_markers"/*
done <<CASES
none|ai-engineering:backend|$hostile_repository/src/new.txt
none|ai-engineering:learning|$hostile_repository/.agents/learnings/x.md
ask||$hostile_repository/x/ai-engineering/tokens/t
deny||$hostile_repository/.git/ai-engineering/tokens/t
CASES
expect_equal "fix round 4 RR3-1: the hostile fixture's state file is still stat-dirty and unchanged" '{"status":"draft"}' "$(cat "$hostile_repository/.agents/specs/active/WORK-1.state.json")"

# RR3-2: the fallback (odd spaces, CR, a dynamic program, an oversized command, a parser limit or
# timeout) keeps the N6(a)/(b), NR-4 and whole-tree classes: their words ask. Main session.
fix4_table "RR3-2 fallback" "$agent_repository" <<'CASES'
m|ask|git stash && X=@NBSP@
m|ask|git reset --hard && X=@NBSP@
m|ask|git restore . && X=@NBSP@
m|ask|git checkout -- . && X=@NBSP@
m|ask|git switch other && X=@CR@
m|ask|git merge other && X=@EMSP@
m|ask|git rebase other && X=@IDSP@
m|ask|git cherry-pick other && X=@FF@
m|ask|git revert other && X=@VT@
m|ask|git clean -fd && X=@NBSP@
m|ask|git mv a b && X=@NBSP@
m|ask|git am mails.mbox && X=@NBSP@
m|ask|git read-tree HEAD && X=@NBSP@
m|ask|git checkout-index -a && X=@NBSP@
m|ask|git update-index --index-info && X=@NBSP@
m|ask|git hash-object -w --stdin-paths && X=@NBSP@
m|ask|patch -p1 < fix.patch && X=@NBSP@
m|ask|cp -R src/. . && X=@NBSP@
m|ask|cp -a src/. . && X=@NBSP@
m|ask|rsync -a src/ . && X=@NBSP@
m|ask|ditto src . && X=@NBSP@
m|ask|tar -xf a.tar && X=@NBSP@
m|ask|unzip a.zip && X=@NBSP@
m|ask|cpio -i < a.cpio && X=@NBSP@
m|ask|pax -r < a.pax && X=@NBSP@
m|ask|7z x a.7z && X=@NBSP@
m|ask|$(echo ls) x; git stash
m|none|cp a b && Y=@NBSP@
m|none|tar -cf a.tar src && Y=@NBSP@
m|none|git status && X=@NBSP@
m|none|git commit -m x && X=@NBSP@
o|none|git commit -m x && X=@NBSP@
CASES

# RR3-3 owner ruling: "unparseable => deny" is forbidden; "unparseable + an independently established
# prohibited operation => deny" is allowed. A specialist's Git write that the fallback establishes
# directly (a literal git in command position, a literal write subcommand or non-read form) is
# denied on every fallback path; anything it cannot establish asks and is never denied.
fix4_table "RR3-3 fallback deny" "$agent_repository" <<'CASES'
b|deny|git stash && X=@CR@
b|deny|git stash && X=@EMSP@
b|deny|git stash && X=@IDSP@
b|deny|git stash && X=@FF@
b|deny|git stash && X=@VT@
b|deny|git stash && X=@ZWSP@
b|deny|git stash\nX=@NBSP@
b|deny|git stash\necho "unclosed
b|deny|$(echo ls) x; git stash
b|deny|git stash push -m wip && X=@NBSP@
b|deny|git stash pop && X=@NBSP@
b|deny|git commit -m x && X=@NBSP@
b|deny|git push origin feature && X=@NBSP@
b|deny|git checkout other && X=@NBSP@
b|deny|git -C sub commit -m x && X=@NBSP@
b|deny|/usr/bin/git commit -m x && X=@NBSP@
b|deny|GIT_PAGER=cat git commit -m x && X=@NBSP@
b|deny|if git commit -m x; then :; fi; X=@NBSP@
b|deny|(git stash) && X=@NBSP@
b|deny|{ git stash; } && X=@NBSP@
b|deny|ls && git stash && X=@NBSP@
b|deny|git branch new-branch && X=@NBSP@
b|deny|git branch -D old && X=@NBSP@
b|deny|git tag v1 && X=@NBSP@
b|deny|git tag -d v1 && X=@NBSP@
b|deny|git worktree add ../x && X=@NBSP@
b|deny|git remote add o https://example.com/r.git && X=@NBSP@
b|deny|git config --unset core.pager && X=@NBSP@
b|deny|git config set core.pager less && X=@NBSP@
f|deny|git stash && X=@NBSP@
p|deny|git stash && X=@NBSP@
q|deny|git stash && X=@NBSP@
s|deny|git stash && X=@NBSP@
l|deny|git stash && X=@NBSP@
m|ask|git stash && X=@CR@
o|ask|git stash && X=@NBSP@
CASES
fix4_table "RR3-3 fallback not established" "$agent_repository" <<'CASES'
b|ask|git "$SUB" x && X=@NBSP@
b|ask|$G stash && X=@NBSP@
b|ask|echo "git commit -m x" && X=@NBSP@
b|ask|echo 'git stash' && X=@NBSP@
b|ask|cat <<'EOF'\ngit commit -m x\nEOF\nX=@NBSP@
b|ask|bash -c 'git stash' && X=@NBSP@
b|ask|# git commit -m x\nX=@NBSP@
b|ask|git config core.pager && X=@NBSP@
b|ask|git frobnicate && X=@NBSP@
b|ask|git stash && echo "unclosed
b|ask|echo a) git commit -m x
b|ask|git@NBSP@stash
b|ask|git branch && X=@NBSP@
b|none|git status && X=@NBSP@
b|none|git log --oneline && X=@NBSP@
CASES
# The fallback deny names the operation and the coordinator, and is logged as a fallback deny.
reason="$(agent_output "git stash && X=$no_break_space" "$agent_repository" b | jq -r '.hookSpecificOutput.permissionDecisionReason')"
expect_contains "fix round 4 RR3-3: the fallback deny names the Git write" "git stash is not on the read-only Git list for this agent: the coordinator owns Git" "$reason"
expect_equal "fix round 4 RR3-3: the fallback deny is logged as a fallback decision" "deny fallback git-write-by-subagent" \
  "$(tail -n 1 "$agent_repository/.git/ai-engineering/guard-log.jsonl" | jq -r '[.decision, .parseMode, (.classes | index("git-write-by-subagent") | if . == null then "missing" else "git-write-by-subagent" end)] | join(" ")')"
# Oversized commands (over the 256 KB parser budget) and a parser limit: still denied when established.
{ printf 'git stash && echo '; i=0; while [ "$i" -lt 27000 ]; do printf 'aaaaaaaaaa'; i=$((i + 1)); done; } >"$work_directory/oversize-word.txt"
{ printf "cat <<'EOF'\n"; i=0; while [ "$i" -lt 9000 ]; do printf 'line %s of inert padding text\n' "$i"; i=$((i + 1)); done; printf 'EOF\ngit stash\n'; } >"$work_directory/oversize-heredoc.txt"
# shellcheck disable=SC2016 # the literal text `$((` is the parser-limit command under test
{ printf 'git stash\n'; i=0; while [ "$i" -lt 3000 ]; do printf '$(('; i=$((i + 1)); done; printf 'x\n'; } >"$work_directory/parser-limit.txt"
for fixture in oversize-word oversize-heredoc parser-limit; do
  fixture_bytes="$(wc -c <"$work_directory/$fixture.txt" | tr -d ' ')"
  case "$fixture" in oversize-*) if [ "$fixture_bytes" -gt 262144 ]; then pass; else fail "fix round 4 RR3-3: $fixture is only $fixture_bytes bytes"; fi ;; esac
  for agent in ai-engineering:backend ""; do
    jq -n --rawfile command "$work_directory/$fixture.txt" --arg cwd "$agent_repository" --arg agent "$agent" \
      '{tool_input: {command: $command}, cwd: $cwd} + (if $agent == "" then {} else {agent_type: $agent} end)' >"$work_directory/$fixture.json"
    expect_equal "fix round 4 RR3-3: $fixture ($fixture_bytes bytes, agent ${agent:-main})" "$([ -n "$agent" ] && echo deny || echo ask)" \
      "$(decision_of "$("$scripts/guard-bash.sh" <"$work_directory/$fixture.json")")"
  done
done
# Soft uncertainty: the parse is sound, so its deny stands.
fix4_table "RR3-3 soft uncertainty" "$agent_repository" <<'CASES'
b|deny|echo x > r.sh; ./build.sh; git stash
b|deny|echo x > r.sh; ./build.sh; git config core.hooksPath h
CASES

# RR3-4 to RR3-7 against the state fixture (main holds WORK-1 in draft; same: only src changes;
# differs: the state is approved). Additions: merged, a merge of differs into main (parent 1 holds
# the draft state, parent 2 the approved one); amb, a branch at same and a tag at differs; tags at
# same and differs; nostate and symlinked (.agents/specs replaced by a symbolic link); spec-notes
# (only a spec Markdown file changes); and a second worktree, detached at same.
git -C "$state_fixture" checkout -q -b merged main
git -C "$state_fixture" -c user.name=test -c user.email=test@example.com merge -q --no-ff -m merged differs
git -C "$state_fixture" checkout -q -b nostate main
printf 'notes\n' >"$state_fixture/.agents/specs/active/notes.md"
git -C "$state_fixture" rm -q .agents/specs/active/WORK-1.state.json && commit_state_fixture "no state"
git -C "$state_fixture" checkout -q -b symlinked nostate
rm -rf "$state_fixture/.agents/specs" && mkdir -p "$state_fixture/elsewhere" && printf 'x\n' >"$state_fixture/elsewhere/keep.txt"
ln -s ../elsewhere "$state_fixture/.agents/specs" && commit_state_fixture "specs is a link"
git -C "$state_fixture" checkout -q -b spec-notes main
printf 'spec\n' >"$state_fixture/.agents/specs/active/WORK-1.md" && commit_state_fixture "spec notes only"
git -C "$state_fixture" checkout -q main
git -C "$state_fixture" branch amb same && git -C "$state_fixture" tag amb differs
git -C "$state_fixture" tag tag-same same && git -C "$state_fixture" tag tag-differs differs
state_worktree="$work_directory/state-worktree"
git -C "$state_fixture" worktree add -q --detach "$state_worktree" same
if [ "$(git -C "$state_fixture" rev-parse --abbrev-ref HEAD)" = main ] && [ -z "$(git -C "$state_fixture" status --porcelain)" ] \
  && [ "$(git -C "$state_fixture" rev-parse merged^2)" = "$(git -C "$state_fixture" rev-parse differs)" ] \
  && [ "$(git -C "$state_fixture" ls-tree symlinked .agents/specs | cut -c1-6)" = 120000 ] && [ -d "$state_worktree/src" ]; then pass
else fail "fix round 4: the state fixture additions are not as intended"; fi
# Option B (2026-10-12): every line below that was none (identical state found by the hook-time
# check) now asks; the asks are unchanged. The value-flag forms (RR3-4) must still be recognised
# as state-changing, which these lines keep testing.
fix4_table "RR3-4 to RR3-7" "$state_fixture" <<'CASES'
m|ask|git rebase -m same
m|ask|git rebase -m differs
m|ask|git checkout -m same
m|ask|git checkout -m differs
m|ask|git switch -m same
m|ask|git cherry-pick -x same
m|ask|git cherry-pick -x differs
m|ask|git cherry-pick -s same
m|ask|git revert -s same
m|ask|git revert -s differs
m|ask|git cherry-pick -m 1 merged
m|ask|git cherry-pick -m 2 merged
m|ask|git cherry-pick --mainline=2 merged
m|ask|git cherry-pick -m2 merged
m|ask|git revert -m 1 merged
m|ask|git cherry-pick -m x merged
m|ask|git checkout amb
m|ask|git switch amb
m|ask|git merge amb
m|ask|git merge tag-same
m|ask|git merge tag-differs
m|ask|git checkout tag-same
m|ask|git switch symlinked
m|ask|git cherry-pick symlinked
m|ask|git cherry-pick spec-notes
m|ask|git switch spec-notes
m|ask|printf '%s' 0 > .git/refs/heads/same && git switch same
m|ask|make sync && git switch same
m|ask|npm install && git switch same
m|ask|X=$(make sync) git switch same
m|ask|echo start && git switch same
m|ask|cd src && git switch same
m|ask|cd src && cd .. && git switch same
m|ask|cd ~ && git switch same
m|ask|cd - && git switch same
m|ask|cd "$D" && git switch same
m|ask|GIT_DIR=x git switch same
m|ask|export GIT_INDEX_FILE=x; git switch same
m|ask|GIT_PAGER=cat git switch same
CASES
# Option B: the reasons no longer name a ref comparison (none is made); they name the operation.
reason="$(agent_output 'git checkout amb' "$state_fixture" m | jq -r '.hookSpecificOutput.permissionDecisionReason')"
expect_contains "Option B RR3-5: the ask names the operation" "git checkout <branch> can replace protected state" "$reason"
reason="$(agent_output 'git cherry-pick -m 1 merged' "$state_fixture" m | jq -r '.hookSpecificOutput.permissionDecisionReason')"
expect_contains "Option B RR3-4: the ask names the operation" "git cherry-pick can replace protected state" "$reason"
# RR3-6: worktrees and subdirectories. Option B: all ask (the none lines were identical-state checks).
expect_equal "fix round 4 RR3-6: cd into a second worktree asks" ask "$(decision_of "$(agent_output "cd $state_worktree && git switch same" "$state_fixture" m)")"
expect_equal "Option B RR3-6: in the second worktree, a merge asks" ask "$(decision_of "$(agent_output 'git merge main' "$state_worktree" m)")"
expect_equal "fix round 4 RR3-6: in the second worktree, a switch asks" ask "$(decision_of "$(agent_output 'git switch differs' "$state_worktree" m)")"
expect_equal "Option B RR3-6: from a subdirectory, a switch asks" ask "$(decision_of "$(agent_output 'git switch same' "$state_fixture/src" m)")"
expect_equal "Option B RR3-6: from a subdirectory, cd .. && switch asks" ask "$(decision_of "$(agent_output 'cd .. && git switch same' "$state_fixture/src" m)")"
# RR3-7: untracked state (whether state files are tracked is open until WORK-002).
printf '{"status":"approved"}\n' >"$state_fixture/.agents/specs/active/WORK-2.state.json"
fix4_table "RR3-7 untracked state" "$state_fixture" <<'CASES'
m|ask|git checkout -f same
m|ask|git switch --discard-changes same
m|ask|git checkout -f
m|ask|git switch same
m|ask|git stash
m|ask|git stash -u
m|ask|git stash push --include-untracked
m|ask|git stash -a
m|ask|git clean -f
m|ask|git clean -f .
m|none|git clean -f src
CASES
rm -f "$state_fixture/.agents/specs/active/WORK-2.state.json"
# Option B: these were none on a clean tree (checked at hook time); they ask now.
fix4_table "RR3-7 clean tree" "$state_fixture" <<'CASES'
m|ask|git checkout -f same
m|ask|git checkout -f
CASES

# RR3-8: ~, ~+, ~-, ~user, cd -, a bare cd, popd and pushd with no directory are unresolved; a tilde
# is never narrowed (N6(c)); `..` never cancels an unresolved component.
fix4_table "RR3-8" "$agent_repository" <<'CASES'
m|ask|cd && cp -R x .
m|ask|cd ~ && cp -R x .
m|ask|cd ~/.. && cp -R x repo-copy
m|ask|pushd /tmp && popd && cp -R x .
m|ask|pushd +1 && cp -R x .
m|ask|cd "$D" && cd .. && cp -R x out
m|ask|cp -R x ~user/out
m|ask|tar -xf a.tar -C ~-
m|deny|cd ~ && echo x > .agents/specs/active/WORK-9.state.json
m|none|cd src && cp -R x out
m|none|cp -R x build/*/
CASES

# RR3-9: patch names in C-style quotes are decoded, context-diff headers are read, and patch's
# reject and output files are write targets.
fix4_table "RR3-9" "$agent_repository" <<'CASES'
m|deny|git apply <<'EOF'\ndiff --git "a/.agents/specs/active/W.state\056json" "b/.agents/specs/active/W.state\056json"\nEOF
m|deny|git apply <<'EOF'\nrename from src/x\nrename to ".agents/specs/active/W\056state.json"\nEOF
m|deny|patch -p1 <<'EOF'\n--- "a/.agents/specs/active/W.\303\251.json"\n+++ "b/.agents/specs/active/W.\303\251.json"\nEOF
m|deny|patch -p1 --reject-file=.agents/specs/active/WORK-9.state.json < fix.patch
m|deny|patch -p1 -o .agents/specs/active/WORK-9.state.json < fix.patch
m|deny|patch -p1 -o.agents/specs/active/WORK-9.state.json < fix.patch
m|none|patch -p1 <<'EOF'\n--- "a/src/my file"\n+++ "b/src/my file"\nEOF
m|none|patch -p0 <<'EOF'\n*** src/x\n--- src/x\n***************\nEOF
CASES

# RR3-10: more programs that write a named file deny for every caller when it is the store.
fix4_table "RR3-10" "$agent_repository" <<'CASES'
m|deny|yq --inplace '.a=1' .agents/specs/active/WORK-9.state.json
m|deny|sort -o.agents/specs/active/WORK-9.state.json x
m|deny|sort -uo .agents/specs/active/WORK-9.state.json x
m|deny|sort --output=.agents/specs/active/WORK-9.state.json x
m|deny|xxd in.bin .agents/specs/active/WORK-9.state.json
m|deny|vim -es .agents/specs/active/WORK-9.state.json
m|deny|vi -e .agents/specs/active/WORK-9.state.json
m|deny|ex .agents/specs/active/WORK-9.state.json
m|deny|tar -czf .agents/specs/active/WORK-9.state.json src
m|deny|tar czf .agents/specs/active/WORK-9.state.json src
m|deny|tar --create --file=.agents/specs/active/WORK-9.state.json src
m|deny|zip .agents/specs/active/WORK-9.state.json src/app.ts
m|deny|base64 -i in.txt -o .agents/specs/active/WORK-9.state.json
m|deny|less -o .agents/specs/active/WORK-9.state.json notes.txt
m|deny|split -l 1 in.txt .agents/specs/active/WORK- --additional-suffix=.state.json
m|deny|csplit -f .agents/specs/active/WORK- -b '%02d.state.json' in.txt 1
m|deny|iconv -f utf-8 -t ascii -o .agents/specs/active/WORK-9.state.json in.txt
m|deny|gzip .agents/specs/active/WORK-9.state.json
m|deny|gunzip .agents/specs/active/WORK-9.state.json.gz
m|deny|mktemp .agents/specs/active/WORK-XXXXXX.state.json
b|deny|sort -o .agents/specs/active/WORK-9.state.json x
m|none|sort -o out.txt in.txt
m|none|uniq in.txt
m|none|uniq in.txt out.txt
m|none|xxd in.bin
m|none|gzip -c .agents/specs/active/WORK-9.state.json
m|none|tar -tf a.tar
m|none|zip out.zip .agents/specs/active/WORK-9.state.json
m|none|split -l 1 in.txt out/part-
m|none|mktemp -d
m|none|less notes.txt
CASES

# RR3-11: Git variables set through eval text, a sourced file this submission wrote, printf -v or
# read reach later git commands (restricted agents are denied them).
fix4_table "RR3-11" "$agent_repository" <<'CASES'
b|deny|eval "export GIT_SSH_COMMAND='ssh -i k'"; git fetch
b|deny|printf -v GIT_PAGER '%s' less; git log
b|deny|read GIT_DIR < dir.txt; git status
b|deny|read -r GIT_EDITOR <<< vi; git status
b|deny|cat > env.sh <<'EOF'\nexport GIT_PAGER=less\nEOF\nsource env.sh; git log
b|deny|set -a; GIT_PAGER=less; git log
b|none|printf -v NAME '%s' x; git status
b|none|read -r line < f.txt; git status
b|none|eval 'export NODE_ENV=test' && git status
m|none|eval 'export GIT_PAGER=less' && git log
CASES

# RR3-12: write-then-run keys ignore case (APFS), a different spelling is not exact, and a known file
# that a writer names again (or any program that can write without naming it) is no longer known.
# Closure option 1: the two file-backed `git apply` lines after chmod and cat were none, now ask.
fix4_table "RR3-12" "$agent_repository" <<'CASES'
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ncp other.patch f.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nmv other.patch f.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nln -sf other.patch f.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nsed -i 's/x/y/' f.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nsudo cp other.patch F.PATCH\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nbash -c 'cp other.patch f.patch'\ngit apply f.patch
m|ask|cat > F.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nchmod 644 f.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ncat f.patch\ngit apply f.patch
m|deny|echo 'terraform apply' > R.sh; sh r.sh
m|deny|echo 'terraform apply' > r.sh; sh r.sh
CASES

# Info: Rscript is matched as an interpreter (program names are lower case).
fix4_table "Rscript" "$agent_repository" <<'CASES'
m|deny|Rscript -e 'writeLines("x", ".agents/specs/active/WORK-9.state.json")'
m|ask|Rscript -e 'DBI::dbExecute(con, "DROP TABLE users")'
CASES

# RR3-13: one deadline for all hook-time Git (5 s), killed with its process group. A git that hangs
# (a PATH shim standing in for a stuck repository) gives ask within the deadline, and no process it
# started is left running. The worst case is documented in guard-bash.sh (run_classifier).
slow_git_directory="$work_directory/slow-git"
mkdir -p "$slow_git_directory"
printf '#!/bin/bash\necho $$ >>"%s/pids"\nsleep 30 &\necho $! >>"%s/pids"\nwait\n' "$slow_git_directory" "$slow_git_directory" >"$slow_git_directory/git"
chmod +x "$slow_git_directory/git"
slow_started=$SECONDS
# Option B: `git switch same` asks without any hook-time Git now, so the hanging lookup is reached
# through a bare push (the current-branch lookup) instead.
output="$(agent_input 'git push' "$state_fixture" m | PATH="$slow_git_directory:$PATH" "$scripts/guard-bash.sh")"
slow_elapsed=$((SECONDS - slow_started))
expect_equal "fix round 4 RR3-13: a hanging hook-time git asks" ask "$(decision_of "$output")"
if [ "$slow_elapsed" -le 9 ]; then pass; else fail "fix round 4 RR3-13: the hook took ${slow_elapsed} s with a hanging git (deadline 5 s)"; fi
if [ -s "$slow_git_directory/pids" ]; then pass; else fail "fix round 4 RR3-13: the slow git shim never ran"; fi
slow_left=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  slow_left=""
  while IFS= read -r slow_pid; do kill -0 "$slow_pid" 2>/dev/null && slow_left="$slow_left $slow_pid"; done <"$slow_git_directory/pids"
  [ -n "$slow_left" ] || break
  sleep 0.1
done
expect_equal "fix round 4 RR3-13: no process of the hanging git is left" "" "$slow_left"

# ---------------------------------------------------------------- Option B (re-review 4: NF-1, NF-2, NF-3)
# NF-1: reading a missing object in a partial clone fetches it from the promisor remote, which runs
# its transport; a repository's protocol.ext.allow=always overrides protocol.allow=never, and only a
# Git that knows GIT_NO_LAZY_FETCH stops it. Option B: hook-time Git reads no object. Fixture: a
# --filter=tree:0 --no-checkout clone whose promisor is an ext:: command that touches a marker; a
# PATH shim drops GIT_NO_LAZY_FETCH (an older Git) and records each hook-time Git invocation.
nf1_markers="$work_directory/nf1-markers" nf1_shim="$work_directory/nf1-shim" nf1_client="$work_directory/nf1-client"
mkdir -p "$nf1_markers" "$nf1_shim"
nf1_server="$(new_repository nf1-server main)"
mkdir -p "$nf1_server/.agents/specs/active" "$nf1_server/src"
printf '{"status":"draft"}\n' >"$nf1_server/.agents/specs/active/WORK-1.state.json"
printf 'a\n' >"$nf1_server/src/a.txt"
git -C "$nf1_server" add -A && git -C "$nf1_server" -c user.name=test -c user.email=test@example.com commit -q -m state
git -C "$nf1_server" config uploadpack.allowFilter true
git clone -q --no-local --filter=tree:0 --no-checkout "file://$nf1_server" "$nf1_client" 2>/dev/null
git -C "$nf1_client" config remote.origin.url "ext::sh -c touch% $nf1_markers/fetched% ;false"
git -C "$nf1_client" config protocol.ext.allow always
real_git="$(command -v git)"
printf '#!/bin/bash\nunset GIT_NO_LAZY_FETCH\nprintf "%%s\\n" "$*" >>"%s/calls"\nexec "%s" "$@"\n' "$nf1_shim" "$real_git" >"$nf1_shim/git"
chmod +x "$nf1_shim/git"
# Precondition: the fixture is genuine. Reading a tree with the hook's own options but without
# GIT_NO_LAZY_FETCH runs the promisor command.
env -u GIT_NO_LAZY_FETCH git -C "$nf1_client" -c protocol.allow=never cat-file -p 'HEAD^{tree}' >/dev/null 2>&1
if [ -e "$nf1_markers/fetched" ]; then pass; else fail "Option B NF-1: the partial-clone fixture does not fetch lazily"; fi
rm -f "$nf1_markers"/* "$nf1_shim/calls"
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  output="$(agent_input "$command_text" "$nf1_client" "$agent" | PATH="$nf1_shim:$PATH" "$scripts/guard-bash.sh")"
  expect_equal "Option B NF-1 ($agent): $command_text" "$expected" "$(decision_of "$output")"
  expect_equal "Option B NF-1: no promisor fetch for: $command_text" "" "$(names_in "$nf1_markers")"
  rm -f "$nf1_markers"/*
done <<'CASES'
m|ask|git switch main
m|ask|git checkout main
m|ask|git cherry-pick main
m|ask|git checkout -- .
m|ask|git reset --hard
m|ask|git stash
m|ask|git push
m|ask|cp -R vendor/. .
m|deny|echo x > .git/ai-engineering/tokens/t
b|none|echo hi > src/a.txt
b|deny|git switch main
CASES
for target in "$nf1_client/src/new.txt" "$nf1_client/x/ai-engineering/tokens/t"; do
  write_input "" "$target" "$nf1_client" | PATH="$nf1_shim:$PATH" "$scripts/guard-writes.sh" >/dev/null
done
expect_equal "Option B NF-1: guard-writes caused no promisor fetch" "" "$(names_in "$nf1_markers")"
# The interface is structural: every hook-time Git call was one of the four rev-parse lookups, which
# read no object, tree or index (round 6, F5-3: the ls-files index lookup for the hint is gone).
if [ -s "$nf1_shim/calls" ]; then pass; else fail "Option B NF-1: the Git shim recorded no hook-time call"; fi
expect_equal "Round 6 F5-3: hook-time Git is only the four rev-parse lookups" "" \
  "$(grep -Ev '(^| )(rev-parse --git-common-dir|rev-parse --show-toplevel|rev-parse --show-cdup|rev-parse --abbrev-ref HEAD)$' "$nf1_shim/calls" | head -n 3)"
expect_equal "Round 6 F5-3: no hook-time ls-files, cat-file, diff or hash-object" "" \
  "$(grep -E ' (ls-files|cat-file|diff-tree|diff-index|hash-object|for-each-ref|show|log)( |$)' "$nf1_shim/calls" | head -n 3)"

# NF-2: `-` is the previous branch, an operand: every state-changing form with it asks, and a
# specialist's is denied.
fix4_table "NF-2 previous branch" "$state_fixture" <<'CASES'
m|ask|git checkout -
m|ask|git switch -
m|ask|git checkout -f -
m|ask|git checkout -q -
m|ask|git switch --discard-changes -
m|ask|git merge -
m|ask|git rebase -
m|ask|git cherry-pick -
m|ask|git revert -
m|ask|git checkout - -- .
b|deny|git checkout -
b|deny|git merge -
CASES

# NF-3: a lookup a decision depends on that fails inside a work tree, or that the hook environment
# redirects, turns no decision into ask; it never lowers an ask or a deny. Outside any work tree a
# failed lookup changes nothing. A failing Git (exit 128, as for a refused safe.directory) is a shim.
failing_git_directory="$work_directory/failing-git" no_repository_directory="$work_directory/not-a-repository"
mkdir -p "$failing_git_directory" "$no_repository_directory"
printf '#!/bin/sh\nexit 128\n' >"$failing_git_directory/git" && chmod +x "$failing_git_directory/git"
nf3_bash() { agent_input "$1" "$2" "$3" | env PATH="$failing_git_directory:$PATH" "$scripts/guard-bash.sh"; }
while IFS='|' read -r agent expected command_text; do
  [ -n "$expected" ] || continue
  expect_equal "Option B NF-3 failing git ($agent): $command_text" "$expected" "$(decision_of "$(nf3_bash "$command_text" "$main_repository" "$agent")")"
done <<'CASES'
m|ask|git push
m|ask|cp -R src/ build/
m|deny|echo x > x/ai-engineering/tokens/t
m|ask|git push --force origin feature
b|deny|git commit -m x
m|deny|echo x > .agents/specs/active/WORK-9.state.json
CASES
expect_equal "Option B NF-3: outside a work tree, a failed lookup gives no decision" none "$(decision_of "$(nf3_bash 'git push' "$no_repository_directory" m)")"
expect_equal "Option B NF-3: an unwritable TMPDIR, bare push on main asks" ask \
  "$(decision_of "$(agent_input 'git push' "$main_repository" m | TMPDIR=/nonexistent "$scripts/guard-bash.sh")")"
expect_equal "Option B NF-3: GIT_DIR in the hook environment, bare push from outside a repository asks" ask \
  "$(decision_of "$(agent_input 'git push' "$no_repository_directory" m | env "GIT_DIR=$main_repository/.git" "$scripts/guard-bash.sh")")"
expect_contains "Option B NF-3: the ask names the failed lookup" "a Git lookup this decision depends on" \
  "$(nf3_bash 'git push' "$main_repository" m | jq -r '.hookSpecificOutput.permissionDecisionReason')"
# guard-writes.sh: the token-store and hard-link checks ask when their lookup fails in a work tree;
# a store path still denies, and an ordinary write is unaffected.
printf 'x\n' >"$main_repository/linked-a" && ln -f "$main_repository/linked-a" "$main_repository/linked-b"
nf3_writes() { write_input "" "$1" "$main_repository" | env PATH="$failing_git_directory:$PATH" "$scripts/guard-writes.sh"; }
expect_equal "Option B NF-3 guard-writes: token-store-like path, failing git" ask "$(decision_of "$(nf3_writes "$main_repository/x/ai-engineering/tokens/t")")"
expect_equal "Option B NF-3 guard-writes: hard-linked file, failing git" ask "$(decision_of "$(nf3_writes "$main_repository/linked-a")")"
expect_equal "Option B NF-3 guard-writes: a store path still denies with a failing git" deny "$(decision_of "$(nf3_writes "$main_repository/.agents/specs/active/WORK-9.state.json")")"
expect_equal "Option B NF-3 guard-writes: an ordinary write, failing git" none "$(decision_of "$(nf3_writes "$main_repository/src/new.txt")")"
expect_equal "Option B NF-3 guard-writes: token-store-like path, working git" none "$(decision_of "$(write_input "" "$main_repository/x/ai-engineering/tokens/t" "$main_repository" | "$scripts/guard-writes.sh")")"
expect_equal "Option B NF-3 guard-writes: hard-linked file, working git" none "$(decision_of "$(write_input "" "$main_repository/linked-a" "$main_repository" | "$scripts/guard-writes.sh")")"
rm -f "$main_repository/linked-a" "$main_repository/linked-b"

# ---------------------------------------------------------------- round 6 (re-review 5: F5-1, F5-2, F5-3, P-1, P-2)
# F5-2: in guard-writes.sh every deny check runs before the unverified-lookup ask, so a failed lookup
# (failing-Git shim) or Git variables in the hook environment never lower a deny to ask.
printf 'x\n' >"$main_repository/linked-c" && ln -f "$main_repository/linked-c" "$main_repository/linked-d"
ln -f "$main_repository/.git/config" "$main_repository/config-link"
mkdir -p "$main_repository/.agents/learnings"
printf 'x\n' >"$main_repository/.agents/learnings/linked.md" && ln -f "$main_repository/.agents/learnings/linked.md" "$main_repository/linked-e"
f52_writes() { write_input "$1" "$2" "$main_repository" | env PATH="$failing_git_directory:$PATH" "$scripts/guard-writes.sh"; }
while IFS='|' read -r expected agent target; do
  [ -n "$expected" ] || continue
  expect_equal "Round 6 F5-2 failing git ($agent): $target" "$expected" "$(decision_of "$(f52_writes "$agent" "$target")")"
  expect_equal "Round 6 F5-2 GIT_DIR in the hook environment ($agent): $target" "$expected" \
    "$(decision_of "$(write_input "$agent" "$target" "$main_repository" | env "GIT_DIR=$main_repository/.git" "$scripts/guard-writes.sh")")"
done <<CASES
deny|ai-engineering:learning|$main_repository/x/ai-engineering/tokens/t
deny|ai-engineering:learning|$main_repository/linked-c
deny|ai-engineering:backend|$main_repository/.git/config
deny||$main_repository/x/ai-engineering/tokens/.agents/${long_s}pecs/W.state.json
ask||$main_repository/x/ai-engineering/tokens/t
ask||$main_repository/linked-c
ask|ai-engineering:learning|$main_repository/.agents/learnings/linked.md
none|ai-engineering:learning|$main_repository/.agents/learnings/new.md
CASES
rm -rf "$main_repository/linked-c" "$main_repository/linked-d" "$main_repository/config-link" "$main_repository/linked-e" "$main_repository/.agents/learnings"

# F5-3: the shell-edit hint runs no Git: an existing regular file gets the hint (tracked or not), a
# new file or a device does not; still never a decision.
printf 'x\n' >"$agent_repository/untracked-existing.txt"
while IFS='|' read -r expected command_text; do
  [ -n "$expected" ] || continue
  output="$(agent_output "$command_text" "$agent_repository" b)"
  expect_equal "Round 6 F5-3 hint: $command_text" "$expected" "$(hint_of "$output")"
  expect_equal "Round 6 F5-3 hint is not a decision: $command_text" none "$(decision_of "$output")"
done <<'CASES'
Use Edit/Write for file changes.|echo x > src/app.ts
Use Edit/Write for file changes.|echo x > untracked-existing.txt
none|echo x > another-new-file.txt
none|echo x > /dev/null
CASES
rm -f "$agent_repository/untracked-existing.txt"

# F5-1 (`-` with a hard, keep or merge reset; Git 2.46 rejects `reset --hard -`, but the guard asks
# whatever it resets to), P-1 (abbreviated and =-joined long options, which Git accepts) and P-2
# (`git stash -- <paths>` is a push). Specialists stay denied.
fix4_table "round 6" "$state_fixture" <<'CASES'
m|ask|git reset --hard -
m|ask|git reset --keep -
m|ask|git reset --merge -
m|ask|git reset --hard main
m|none|git reset -q
m|none|git reset HEAD~1 -- src
b|deny|git reset --hard -
m|ask|git reset --har
m|ask|git reset --ke
m|ask|git switch --orph x
m|ask|git switch --orphan=x
m|ask|git checkout --orphan=x
m|ask|git checkout --orph x
m|ask|git checkout --for
m|ask|git checkout --force
m|ask|git cherry-pick --ab
m|ask|git revert --cont
m|ask|git switch --cre topic main
m|ask|git restore --so=HEAD~1 .
m|ask|git restore --source HEAD~1 .
m|none|git restore --staged .
m|ask|git restore --sta .
m|ask|git restore --sta --work .
b|deny|git reset --har
b|deny|git switch --orph x
m|ask|git stash -- .agents/specs
m|ask|git stash -- .
m|ask|git stash push -- src
m|ask|git stash -m wip -- src
m|ask|git stash save
m|ask|git stash apply
m|none|git stash list
m|none|git stash show -p
m|none|git stash drop
m|none|git stash clear
b|deny|git stash -- src
CASES

# Round 7 (re-review 6, N6-1): abbreviated and =-joined value-taking options. Git 2.46.0 and Apple
# Git 2.39.5 both accept every "accepted" form below (scratch-repository check): the pathspec-file
# forms restore the listed files (a state file among them) from the index or an older commit, and
# `stash --m/--mess <word>` takes the word as the message and stashes. Ambiguous forms that Git
# rejects (`restore --s`) still ask. Exemptions keep their exact spelling; specialists stay denied.
fix4_table "round 7 N6-1" "$state_fixture" <<'CASES'
m|ask|git restore --pathspec-fr list.txt
m|ask|git restore --pathspec-from=list.txt
m|ask|git restore --so=HEAD~3 --pathspec-fr list.txt
m|ask|git restore --sou HEAD~3 --pathspec-from list.txt
m|ask|git checkout HEAD~3 --pathspec-fr list.txt
m|ask|git checkout --pathspec-fr=list.txt
m|ask|git checkout --pathspec-from-file=list.txt
m|ask|git checkout --pathspec-from-file list.txt
m|ask|git stash --m list
m|ask|git stash --mess list
m|ask|git stash --mess show
m|ask|git stash --message=list
m|ask|git stash -m list
m|ask|git stash push --pathspec-fr list.txt
m|ask|git reset --pathspec-fr list.txt
m|ask|git restore --s HEAD~1 .
m|none|git restore --staged --pathspec-from-file list.txt
m|none|git restore --sou HEAD~1 src
m|none|git stash list
m|none|git stash show
b|deny|git restore --pathspec-fr list.txt
b|deny|git checkout HEAD~3 --pathspec-fr list.txt
b|deny|git stash --mess list
b|deny|git stash -m list
b|deny|git stash --m show
b|none|git stash list
b|none|git stash show -p
b|deny|git stash --mess list && X=@NBSP@
b|deny|git stash -m list && X=@NBSP@
b|ask|git stash list && X=@NBSP@
CASES

# Closure pass (re-review 7, N7-1): the stash action is the first argument when it is a stash
# subcommand, as Git parses it; otherwise a push. Git 2.46.0 and Apple Git 2.39.5 reject
# `stash <option> list <path>` ("'push' can't be assumed"), so these ask only to stay conservative;
# `stash <option> -- <path>` is the accepted implicit push.
fix4_table "closure N7-1" "$state_fixture" <<'CASES'
m|ask|git stash -u list .agents/specs/active/WORK-1.state.json
m|ask|git stash -q list x
m|ask|git stash -k show x
m|ask|git stash -u drop
m|ask|git stash -q -- .agents/specs/active/WORK-1.state.json
m|none|git stash list
m|none|git stash list --oneline
m|none|git stash show -p stash@{1}
m|none|git stash drop
m|none|git stash clear
b|deny|git stash -u list x
b|none|git stash list --oneline
b|none|git stash show -p stash@{1}
CASES

# RR3-12 closure fix (independent probes 9-12, G12-1 to G12-4): a patch written in the submission
# and then changed in a way the guard cannot read is unknown, so `git apply` asks. Overwrite
# detection fails closed (an unlisted program that names the file counts as a writer; `of=F`,
# `--output=F` and `-oF` name F); `<>` and `>&<file>` writes and a first-write append are unknown.
# Store hunks the submission wrote still deny (deny wins over the unknown-content ask). Harmless
# reads and metadata keep a known patch known. Closure option 1: the six file-backed "harmless
# control" applies (none) now ask, since a patch read from a file is never trusted.
fix4_table "RR3-12 closure" "$agent_repository" <<'CASES'
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ndd if=other.patch of=F.PATCH\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ndd if=other.patch of=f.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nsort -o F.PATCH other.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nsort --output=f.patch other.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nsort -of.patch other.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nbase64 -d -o f.patch other.b64\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nuniq other.patch f.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nmytool --out f.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ncat other.patch 1<>F.PATCH\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\necho x >&f.patch\ngit apply f.patch
m|ask|cat >> f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ngit apply f.patch
m|ask|echo '--- a/src/x' &>> f.patch\ngit apply f.patch
m|ask|cat <<'EOF' | tee -a f.patch\n--- a/src/x\n+++ b/src/x\nEOF\ngit apply f.patch
m|deny|cat > p.diff <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF\ndd if=x of=p.diff\ngit apply p.diff
m|deny|cat > p.diff <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF\nsort -o p.diff x\ngit apply p.diff
m|deny|cat > p.diff <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF\ncat x 1<>p.diff\ngit apply p.diff
m|deny|cat >> p.diff <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF\ngit apply p.diff
m|deny|cat > p.diff <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF\nmytool --out=p.diff\ngit apply p.diff
b|deny|cat > p.diff <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ndd if=x of=p.diff\ngit apply p.diff
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nwc -l f.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nchmod 644 f.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ngrep -c src f.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ncat >> f.patch <<'EOF'\n--- a/src/y\n+++ b/src/y\nEOF\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nmytool --out other.txt\ngit apply f.patch
m|none|echo x 2>&1 > notes.txt
m|none|sort -o sorted.txt names.txt
CASES

# Closure option 1 (owner decision 2026-10-12): a patch read from a file is never trusted, so a
# mutating git apply, git am or patch of a file asks (coordinator), whatever wrote the file. The
# independently confirmed probes r1, r2, r3, r5 (replaced by cp to a directory, curl -O, a symlink made
# first, env -C) now ask; r6 (`cat f.patch | git apply` of store hunks this submission wrote) denies,
# as do store hunks written into any applied file. Content given directly on standard input stays
# judged by content. Dry runs stay none unless an abbreviated --apply (`--ap`, which Git 2.46 and
# 2.39 apply) or --build-fake-ancestor makes them real. Specialists stay denied.
# Changed by the fail-closed patch decision (below), none -> ask: `cat <<'EOF' | git apply` (content
# through a pipeline producer is not one of the exact direct shapes).
fix4_table "closure option 1" "$agent_repository" <<'CASES'
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ncp other/f.patch .\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ncurl -fsSLO https://example.invalid/f.patch\ngit apply f.patch
m|ask|ln -s f.patch g.patch\ncat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\ncat other.patch > g.patch\ngit apply f.patch
m|ask|cat > f.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\nenv -C src cp ../other.patch ../f.patch\ngit apply f.patch
m|deny|cat > f.patch <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF\ncat f.patch | git apply
m|deny|cat > f.patch <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF\ngit apply f.patch
m|deny|cat > f.patch <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF\npatch -p1 < f.patch
m|ask|git apply fix.patch
m|ask|git apply --index fix.patch
m|ask|git am 0001-fix.patch
m|ask|patch -p1 < fix.patch
m|ask|patch -p1 -i fix.patch
m|ask|cat fix.patch | git apply
m|ask|git apply --check --ap fix.patch
m|ask|git apply --stat --apply fix.patch
m|ask|git apply --check --build-fake-ancestor=anc fix.patch
m|none|git apply --check fix.patch
m|none|git apply --stat fix.patch
m|none|patch --dry-run -p1 < fix.patch
m|none|git apply <<'EOF'\n--- a/src/app.ts\n+++ b/src/app.ts\nEOF
m|none|patch -p1 <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|ask|cat <<'EOF' | git apply\n--- a/src/x\n+++ b/src/x\nEOF
m|deny|git apply <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF
b|deny|git apply fix.patch
b|deny|git apply <<'EOF'\n--- a/src/app.ts\n+++ b/src/app.ts\nEOF
CASES

# Fail-closed patch tools (owner decision 2026-10-12). Exemptions only for exact, unwrapped shapes with
# no dynamic word, Git global option, pipeline producer or extra redirection:
#   D1 git apply --check|--stat|--numstat|--summary [-pN] FILE...   none (verified: writes nothing)
#   D2 patch --dry-run [-pN] with stdin one `<` or its own heredoc   none (verified: writes nothing)
#   H1 git apply [-pN] / H2 patch [-pN] with its own heredoc or here-string: judged by content
# Everything else asks; store hunks deny in every shape; specialists deny. First the nine
# independently confirmed gaps (p1-p9: G1 xargs input, G2 a value-taking option before a dry-run
# flag, G3 cat after --, G4 combined or abbreviated patch input options), then unknown shapes.
fix4_table "fail-closed patch tools" "$agent_repository" <<'CASES'
m|ask|xargs git apply <<'EOF'\nfix.patch\nEOF
m|ask|xargs git apply <<< fix.patch
m|ask|git apply --exclude --check fix.patch
m|deny|cat > p.diff <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF\ngit apply --exclude --check p.diff
m|ask|patch -p1 -i --dry-run <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|ask|patch -p1 -fi fix.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|ask|patch -p1 --inp=fix.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|ask|patch -p1 --inp fix.patch <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|ask|cat -- -fix.patch <<'EOF' | git apply\n--- a/src/x\n+++ b/src/x\nEOF
m|ask|git apply --check --exclude=x fix.patch
m|ask|git apply --chec fix.patch
m|ask|git apply --check --ap fix.patch
m|ask|git apply --check -v fix.patch
m|ask|git apply --check
m|ask|git apply --check fix.patch < other.patch
m|ask|git -C . apply --check fix.patch
m|ask|env git apply --check fix.patch
m|ask|patch --dry-run fix.patch
m|ask|patch --dry -p1 < fix.patch
m|ask|patch --dry-run -p1 -o out < fix.patch
m|ask|git apply -R <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|ask|git apply --index <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|ask|git am <<'EOF'\nFrom: x\n--- a/src/x\n+++ b/src/x\nEOF
m|ask|time git apply <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|ask|git apply "$P"
m|ask|git apply <<'EOF' > out.txt\n--- a/src/x\n+++ b/src/x\nEOF
m|deny|git apply -R <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF
m|deny|xargs git apply <<'EOF'\nfix.patch\nEOF\ncat > p.diff <<'EOF'\n--- a/.agents/specs/active/W.state.json\n+++ b/.agents/specs/active/W.state.json\nEOF\ngit apply p.diff
m|none|git apply --check fix.patch two.patch
m|none|git apply --stat -p1 fix.patch
m|none|git apply --numstat fix.patch
m|none|git apply --summary fix.patch
m|none|patch --dry-run -p1 < fix.patch
m|none|patch --dry-run <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|none|git apply <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|none|git apply -p1 <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|none|patch -p1 <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|none|git apply <<< '--- a/src/x'
b|deny|git apply --check --exclude=x fix.patch
b|deny|xargs git apply <<< fix.patch
CASES
# Independent re-review of the fail-closed policy (F1, F2). F1: a heredoc, here-string or `<` on
# another descriptor (3<<, 4<<<, 3<) is not the tool's standard input, so no exemption; fd 0 is.
# F2: the command's own and its producers' text still counts for the store deny in every shape,
# including octal-escaped C-quoted names (a deny that ab7fd33 had lowered to ask).
fix4_table "fail-closed patch tools F1 F2" "$agent_repository" <<'CASES'
m|ask|{ git apply 3<<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF\n} < fix.patch
m|ask|exec < fix.patch; git apply 4<<< x
m|ask|patch --dry-run -p1 3< fix.patch
m|ask|exec < fix.patch; patch -p1 3<<< x
m|none|git apply 0<<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
m|none|patch --dry-run -p1 0< fix.patch
m|deny|time git apply <<'EOF'\ndiff --git "a/.agents/specs/active/W.state\056json" "b/.agents/specs/active/W.state\056json"\nEOF
m|deny|cat <<'EOF' | git apply\ndiff --git "a/.agents/specs/active/W.state\056json" "b/.agents/specs/active/W.state\056json"\nEOF
m|deny|git -C . apply <<'EOF'\ndiff --git "a/.agents/specs/active/W.state\056json" "b/.agents/specs/active/W.state\056json"\nEOF
CASES
# N1 (owner option 3): `<<-` bodies lose their leading tabs, as in Bash, for every heredoc consumer;
# and a `<<-` heredoc is not one of the exact direct patch shapes, so it asks unless a deny applies.
fix4_table "N1 tab-stripped heredocs" "$agent_repository" <<'CASES'
m|deny|git apply <<-'EOF'\n@TAB@diff --git "a/.agents/specs/active/W.state\056json" "b/.agents/specs/active/W.state\056json"\n@TAB@--- "a/.agents/specs/active/W.state\056json"\n@TAB@+++ "b/.agents/specs/active/W.state\056json"\nEOF
m|deny|git apply <<-'EOF'\n@TAB@--- a/.agents/specs/active/W.state.json\n@TAB@+++ b/.agents/specs/active/W.state.json\nEOF
m|ask|git apply <<-'EOF'\n@TAB@--- a/src/x\n@TAB@+++ b/src/x\nEOF
m|deny|patch -p1 <<-'EOF'\n@TAB@--- "a/.agents/specs/active/W.state\056json"\n@TAB@+++ "b/.agents/specs/active/W.state\056json"\nEOF
m|ask|patch -p1 <<-'EOF'\n@TAB@--- a/src/x\n@TAB@+++ b/src/x\n@TAB@EOF
m|deny|git apply <<-'EOF'\n@TAB@@TAB@--- "a/.git/hooks/pre-commit"\n@TAB@+++ "b/.agents/specs/active/W.state\056json"\nEOF
b|deny|git apply <<-'EOF'\n@TAB@--- a/src/x\n@TAB@+++ b/src/x\nEOF
m|ask|psql "$URL" <<-'SQL'\n@TAB@DROP TABLE users;\n@TAB@SQL
m|ask|bash <<-'EOF'\n@TAB@terraform apply\n@TAB@EOF
b|deny|bash <<-'EOF'\n@TAB@git commit -m x\nEOF
m|none|cat <<-'EOF'\n@TAB@hello\n@TAB@EOF
m|none|git apply <<'EOF'\n--- a/src/x\n+++ b/src/x\nEOF
CASES

# CodeRabbit PR #5 (major, CWE-184): curl and wget output-file options with the destination joined
# to the option or after other short options in one cluster (c2, c3, c7, c8 and close spellings)
# are write targets like the exact forms: the authority store denies for every caller, Git's hooks
# and configuration deny for specialists. Ordinary downloads and stdout output stay no decision.
fix4_table "CodeRabbit curl/wget output options" "$agent_repository" <<'CASES'
m|deny|curl -sSLo .agents/specs/active/WORK-9.state.json https://example.invalid/x
m|deny|curl -o.agents/specs/active/WORK-9.state.json https://example.invalid/x
m|deny|wget -O.agents/specs/active/WORK-9.state.json https://example.invalid/x
b|deny|curl -sSLo .git/hooks/pre-commit https://example.invalid/x
m|deny|curl -sSLo.agents/specs/active/WORK-9.state.json https://example.invalid/x
m|deny|curl -fsSL -o .agents/specs/active/WORK-9.state.json https://example.invalid/x
m|deny|curl --output .agents/specs/active/WORK-9.state.json https://example.invalid/x
m|deny|curl -sSLo .git/ai-engineering/tokens/t https://example.invalid/x
m|deny|wget -qO.agents/specs/active/WORK-9.state.json https://example.invalid/x
m|deny|wget -qO .agents/specs/active/WORK-9.state.json https://example.invalid/x
m|deny|wget --output-document=.agents/specs/active/WORK-9.state.json https://example.invalid/x
m|deny|wget -qo .agents/specs/active/WORK-9.state.json https://example.invalid/x
b|deny|wget -qO.git/config https://example.invalid/x
b|deny|curl -fsSLo.git/hooks/pre-commit https://example.invalid/x
m|none|curl -sSLo out.json https://example.invalid/x
m|none|curl -sSL https://example.invalid/x
m|none|wget -qO- https://example.invalid/x
m|none|wget -qO out.html https://example.invalid/x
b|none|curl -fsSLo build/out.json https://example.invalid/x
CASES

# Closure pass: the WORK-001 replacement probe set (tests/guard-probes.txt; not the lost historical
# corpus), one risk-focused line per security boundary, in the agent repository (branch feature).
probe_lines="$(grep -c '^[mb]|' "$repository_directory/tests/guard-probes.txt")"
if [ "$probe_lines" -ge 45 ]; then pass; else fail "closure: the replacement probe set has $probe_lines probes (expected at least 45)"; fi
fix4_table "replacement probes" "$agent_repository" <"$repository_directory/tests/guard-probes.txt"

# ---------------------------------------------------------------- guard log never blocks (FIFO)
# Logging never delays or changes a decision (spec: "a logging failure never changes the decision").
# A FIFO planted as the guard log used to block every logged path: the fallback, floor and
# lookup-failure asks and the fallback deny printed nothing; the parsed ask and deny printed but the
# hook never exited. Now every path prints first, a non-regular log is skipped, and the write runs
# under a 2 s deadline in its own process group (which also covers a FIFO swapped in after the
# type check). Each run here is its own process group, killed with all its children after 8 s.
bounded_guard() { # hook JSON file, then optional NAME=value environment assignments
  local input_file="$1" pid killer start
  shift
  rm -f "$work_directory/bounded.out" "$work_directory/bounded.done"
  start=$SECONDS
  set -m
  ( env "$@" "$scripts/guard-bash.sh" <"$input_file" >"$work_directory/bounded.out" 2>/dev/null; : >"$work_directory/bounded.done" ) &
  pid=$!
  ( sleep 8; kill -KILL -- "-$pid" ) </dev/null >/dev/null 2>&1 &
  killer=$!
  set +m
  wait "$pid" 2>/dev/null
  bounded_seconds=$((SECONDS - start))
  kill -KILL -- "-$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  kill -KILL -- "-$pid" 2>/dev/null
  bounded_output="$(cat "$work_directory/bounded.out" 2>/dev/null)"
  if [ -e "$work_directory/bounded.done" ]; then bounded_done=1; else bounded_done=0; fi
}
fifo_repository="$(new_repository fifo-repo feature)"
mkdir -p "$fifo_repository/.git/ai-engineering"
fifo_log="$fifo_repository/.git/ai-engineering/guard-log.jsonl"
{ printf 'foo'; i=0; while [ "$i" -lt 2500 ]; do printf ' word%s' "$i"; i=$((i + 1)); done; printf ' terraform apply'; } >"$work_directory/fifo-floor.txt"
fifo_cases() { # label|agent|expected|command lines on stdin; environment assignment in $1 (may be empty)
  local label agent expected command_text
  while IFS='|' read -r label agent expected command_text; do
    [ -n "$expected" ] || continue
    command_text="$(expand_characters "$command_text")"
    [ "$command_text" = "@FLOOR@" ] && command_text="$(cat "$work_directory/fifo-floor.txt")"
    agent_input "$command_text" "$fifo_repository" "$agent" >"$work_directory/fifo.json"
    if [ "$label" = "lookup-failure ask" ]; then bounded_guard "$work_directory/fifo.json" "GIT_CONFIG_PARAMETERS='x.y=z'"
    else bounded_guard "$work_directory/fifo.json"; fi
    expect_equal "guard log $1: $label decision" "$expected" "$(decision_of "$bounded_output")"
    expect_equal "guard log $1: $label completes by itself" 1 "$bounded_done"
    if [ "$bounded_seconds" -le 4 ]; then pass; else fail "guard log $1: $label took ${bounded_seconds} s (logging deadline 2 s)"; fi
  done
}
fifo_table='parsed ask|m|ask|terraform apply
fallback ask|m|ask|echo '"'"'unbalanced; terraform apply
floor ask|m|ask|@FLOOR@
lookup-failure ask|m|ask|git push
parsed deny|m|deny|echo x > .agents/specs/active/W.state.json
fallback deny|b|deny|X=@NBSP@ git commit -m x
no decision|m|none|ls'
rm -f "$fifo_log"; mkfifo "$fifo_log"
fifo_cases "FIFO" <<<"$fifo_table"
if [ -p "$fifo_log" ]; then pass; else fail "guard log FIFO: the FIFO was replaced or removed"; fi
# Control: a regular log keeps working, one line per ask or deny (six here), never for no decision.
rm -f "$fifo_log"
fifo_cases "regular file" <<<"$fifo_table"
expect_equal "guard log regular file: one line per ask or deny" 6 "$(wc -l <"$fifo_log" | tr -d ' ')"
# Deadline (stands in for a FIFO swapped in between the type check and the open, which a test cannot
# time reliably): a Git that hangs, reached only from the log write (`npm publish` asks and its text
# triggers no earlier branch, root or common-directory lookup; `terraform` would, through "rm"). The
# decision is printed, the hook finishes within the deadline, and the hung Git is gone once its own
# lookup deadline (5 s) passes.
stalled_git_directory="$work_directory/stalled-git"
mkdir -p "$stalled_git_directory"
printf '#!/bin/bash\necho $$ >>"%s/pids"\nsleep 30 &\necho $! >>"%s/pids"\nwait\n' "$stalled_git_directory" "$stalled_git_directory" >"$stalled_git_directory/git"
chmod +x "$stalled_git_directory/git"
agent_input 'npm publish' "$fifo_repository" m >"$work_directory/fifo.json"
bounded_guard "$work_directory/fifo.json" "PATH=$stalled_git_directory:$PATH"
expect_equal "guard log deadline: a stalled log write still asks" ask "$(decision_of "$bounded_output")"
expect_equal "guard log deadline: the hook completes by itself" 1 "$bounded_done"
if [ "$bounded_seconds" -le 4 ]; then pass; else fail "guard log deadline: the hook took ${bounded_seconds} s (logging deadline 2 s)"; fi
if [ -s "$stalled_git_directory/pids" ]; then pass; else fail "guard log deadline: the stalled git shim never ran"; fi
stalled_left=""
for _ in $(seq 1 80); do
  stalled_left=""
  while IFS= read -r stalled_pid; do kill -0 "$stalled_pid" 2>/dev/null && stalled_left="$stalled_left $stalled_pid"; done <"$stalled_git_directory/pids"
  [ -n "$stalled_left" ] || break
  sleep 0.1
done
expect_equal "guard log deadline: no stalled git process is left" "" "$stalled_left"

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
  # shellcheck source=../plugins/ai-engineering/scripts/lib.sh
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
