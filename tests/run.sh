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
# Hermetic Git: no inherited variable redirects or reshapes Git, and the user-level
# configuration is a fixture (HOME and XDG_CONFIG_HOME), so a developer's own settings cannot
# change results. GIT_CONFIG_GLOBAL and GIT_CONFIG_NOSYSTEM are not used: the guard under test
# treats them as variables that change which configuration Git reads. System configuration
# still applies.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR \
  GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_REPLACE_REF_BASE GIT_NO_REPLACE_OBJECTS \
  GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_PAGER GIT_ATTR_SOURCE GIT_ATTR_NOSYSTEM GIT_TEMPLATE_DIR GIT_EXEC_PATH \
  GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
export HOME="$work_directory/home" XDG_CONFIG_HOME="$work_directory/home/.config"
mkdir -p "$XDG_CONFIG_HOME/git"
printf '[user]\n\tname = test\n\temail = test@example.com\n' >"$HOME/.gitconfig"

passed=0
failed=0
pass() { passed=$((passed + 1)); }
fail() { failed=$((failed + 1)); echo "FAIL: $1"; }
skipped=0
skip() { skipped=$((skipped + 1)); echo "SKIP: $1"; } # a precondition this machine lacks; never a pass
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

# ---------------------------------------------------------------- WORK-003 C1: change classifier
classifier="$scripts/classify-change.sh"
classify_git() { local repository="$1"; shift; git -C "$repository" -c user.name=test -c user.email=test@example.com "$@" </dev/null; }

# Prepares branch "scratch" from "main" in a repository: appends a line to each given path.
scratch_commit() {
  local repository="$1" relative_path
  shift
  classify_git "$repository" checkout -q -f -B scratch main
  for relative_path in "$@"; do
    mkdir -p "$(dirname "$repository/$relative_path")"
    printf 'changed\n' >>"$repository/$relative_path"
  done
  classify_git "$repository" add -A
  classify_git "$repository" commit -q -m scratch
}
# Same, appending one given line (which may be several words) to one path.
scratch_commit_line() {
  local repository="$1" relative_path="$2" line="$3"
  classify_git "$repository" checkout -q -f -B scratch main
  mkdir -p "$(dirname "$repository/$relative_path")"
  printf '%s\n' "$line" >>"$repository/$relative_path"
  classify_git "$repository" add -A
  classify_git "$repository" commit -q -m scratch
}
# Runs the classifier main..scratch; sets classify_output and classify_status.
classify_run() {
  local repository="$1"
  shift
  classify_output="$("$classifier" ${1+"$@"} main scratch "$repository" 2>"$work_directory/classify-stderr.txt")"
  classify_status=$?
}
floor_of() { jq -r '.floorTier' <<<"$classify_output" 2>/dev/null; }
tier_of() { jq -r --arg path "$1" --arg side "$2" '[.paths[] | select(.path == $path and .side == $side)][0].tier | tostring' <<<"$classify_output" 2>/dev/null; }
reasons_of() { jq -r --arg path "$1" --arg side "$2" '[.paths[] | select(.path == $path and .side == $side)][0].reasons | join(",")' <<<"$classify_output" 2>/dev/null; }
expect_floor() {
  case "$2" in
    '>='*) if [ "$3" -ge "${2#>=}" ] 2>/dev/null; then pass; else fail "$1 (expected floor $2, got '$3')"; fi ;;
    *) expect_equal "$1" "$2" "$3" ;;
  esac
}
seed_classifier_repository() {
  local repository="$1" line_number
  mkdir -p "$repository/docs" "$repository/src" "$repository/.github/workflows"
  for line_number in 1 2 3 4 5 6 7 8 9 10; do printf 'documentation line %s\n' "$line_number" >>"$repository/docs/a.md"; done
  printf 'name: x\n' >"$repository/.github/workflows/x.yml"
  printf 'export const b = 1;\n' >"$repository/src/b.ts"
  classify_git "$repository" add -A
  classify_git "$repository" commit -q -m seed
}

classifier_repository="$(new_repository classifier-repo main)"
seed_classifier_repository "$classifier_repository"

# Glob matcher (the single matcher behind defaults, riskPaths, copyPaths and definedBy)
while IFS='|' read -r glob_under_test path_under_test expected_match; do
  [ -n "$glob_under_test" ] || continue
  "$classifier" --glob-match "$glob_under_test" "$path_under_test"
  expect_equal "glob '$glob_under_test' vs '$path_under_test'" "$expected_match" "$?"
done <<'GLOB_CASES'
docs/**|docs/a.md|0
docs/**|docs/x/y/z.md|0
docs/**|docs|1
docs/**|other/docs/a.md|1
**/*.sql|a.sql|0
**/*.sql|db/x/a.sql|0
*.sql|a.sql|0
*.sql|db/a.sql|1
**/x|x|0
**/x|a/b/x|0
**/x|a/bx|1
a/**/b|a/b|0
a/**/b|a/c/d/b|0
a/*/b|a/c/b|0
a/*/b|a/c/d/b|1
a/*/b|a/b|1
a?c|abc|0
a?c|a/c|1
a?c|ac|1
A.md|a.md|1
a.b|axb|1
a+b|a+b|0
a+b|aab|1
a[x]|a[x]|0
a[x]|ax|1
a(b)|a(b)|0
**|any/thing/here|0
*|a/b|1
.env*|.env.local|0
.env*|config/.env|1
**/.env*|config/.env.production|0
Dockerfile*|Dockerfile.dev|0
docker-compose*.y*ml|docker-compose.override.yaml|0
GLOB_CASES
while IFS='|' read -r version_text expected_support; do
  [ -n "$version_text" ] || continue
  "$classifier" --git-version-check "$version_text"
  expect_equal "git version check: '$version_text'" "$expected_support" "$?"
done <<'GIT_VERSION_CASES'
git version 2.46.0|0
git version 2.40.0|0
git version 2.39.5|1
git version 2.9.1|1
git version 3.0.0|0
git version 2.50.1 (Apple Git-155)|0
git version 2.39.5 (Apple Git-154)|1
git version 1.9.0|1
git version|1
not git|1
|1
GIT_VERSION_CASES
expect_equal "git version check: an empty string is unsupported" 1 "$("$classifier" --git-version-check '' >/dev/null 2>&1; echo $?)"
expect_equal "glob: a glob starting with a dash is a glob, not an option" 1 "$("$classifier" --glob-match '-x' 'y' >/dev/null 2>&1; echo $?)"

# Tier tables: one single-path commit per row ("expected floor|path")
while IFS='|' read -r expected_floor path_under_test; do
  [ -n "$expected_floor" ] || continue
  scratch_commit "$classifier_repository" "$path_under_test"
  classify_run "$classifier_repository"
  expect_equal "classify: '$path_under_test' exits 0" 0 "$classify_status"
  expect_floor "classify: '$path_under_test'" "$expected_floor" "$(floor_of)"
done <<'TIER_CASES'
0|docs/a.md
0|README.md
0|docs/notes.txt
0|docs/guide/deep/page.markdown
0|CHANGELOG.md
0|docs/my file.md
1|src/my file.ts
1|src/b.ts
1|.agents/learnings/x.md
1|.agents/specs/active/OTHER.state.json
1|.agents/specs/active/WORK-001.state.json
1|.agents/specs/active/WORK-001.log.md
2|.agents/gates.json
1|AGENTS.md
1|CLAUDE.md
1|CLAUDE.local.md
1|docs/CLAUDE.md
1|packages/x/AGENTS.md
1|docs/AGENTS.md
1|agents.md
1|claude.md
2|.claude/agents/x.md
2|.claude/commands/x.md
2|.claude/skills/s/SKILL.md
2|.claude/settings.json
2|packages/x/.claude/settings.json
1|plugins/p/skills/s/SKILL.md
1|plugins/p/commands/c.md
2|plugins/p/agents/a.md
2|docs/agents/a.md
2|plugins/p/hooks/hooks.json
2|hooks/hooks.json
2|plugins/p/.claude-plugin/plugin.json
2|.claude-plugin/marketplace.json
1|docs/skills/SKILL.md
1|docs/skills/guide.md
1|docs/commands/c.md
1|.github/pull_request_template.md
1|.github/ISSUE_TEMPLATE/bug.md
2|.github/workflows/ci.yml
2|.github/CODEOWNERS
2|db/migrations/001_init.ts
2|db/migrate/1.rb
2|src/migration.ts
2|schema.sql
2|sql/queries/report.sql
2|pnpm-lock.yaml
2|packages/a/package-lock.json
2|go.sum
2|yarn.lock
2|package.json
2|packages/web/package.json
2|Cargo.toml
2|requirements-dev.txt
2|.env.example
2|.env
2|config/prod.env
2|certs/server.pem
2|secrets/db.txt
2|infra/main.tf
2|Dockerfile
2|services/api/Dockerfile.dev
2|k8s/deploy.yaml
2|docker-compose.yml
2|deploy/helm/values.yaml
2|fly.toml
2|.gitlab-ci.yml
2|Jenkinsfile
2|.circleci/config.yml
2|src/auth/login.ts
2|src/lib/AuthService.ts
2|src/oauthClient.ts
2|src/SSOLogin.ts
2|src/session.ts
2|src/rbac/roles.ts
2|src/PermissionsGuard.ts
2|src/authentication.ts
2|src/token-store.ts
2|src/api/passwords.ts
2|src/Authorization/policy.ts
2|docs/authentication.md
1|src/author.ts
1|src/authors/list.ts
1|src/tokenizer.ts
0|docs/authors.md
1|src/utils.ts
1|tools/build.sh
>=1|.Agents/x.md
2|.AGENTS/gates.json
2|.ENV
2|Package.json
2|.mcp.json
2|tools/.mcp.json
2|plugins/p/agents/sub/x.md
2|main.tf.json
2|prod.tfvars.json
2|Containerfile
2|deploy/main.bicep
2|flake.lock
2|ios/Podfile.lock
2|pubspec.yaml
2|pubspec.lock
2|.pnpmfile.cjs
2|.yarn/releases/yarn-4.cjs
2|gradle/wrapper/gradle-wrapper.properties
2|.mvn/wrapper/maven-wrapper.properties
2|gradle/libs.versions.toml
2|Directory.Packages.props
2|my.gemspec
2|.gitmodules
2|svc/alembic/versions/0001_x.py
2|prisma/schema.prisma
2|src/jwt.ts
2|src/CsrfGuard.ts
2|src/mfa.ts
2|src/otp.ts
2|src/totp.ts
2|src/passwd.ts
2|src/logins.ts
2|src/roles.ts
2|src/role.ts
2|src/policy.ts
2|src/policies.ts
1|src/hotpot.ts
1|src/footprint.ts
1|src/signin.ts
1|src/signup.ts
1|src/security.ts
>=1|docs/conf.py
>=1|docs/.vitepress/config.ts
>=1|docs/scripts/x.sh
0|docs/guide.md
0|docs/img/a.PNG
0|docs/diagrams/flow.drawio
2|deploy/kustomization.yaml
2|kustomization.yml
2|template.yaml
2|template.yml
1|src/template.yaml
TIER_CASES

# Mixed changes take the highest tier
scratch_commit "$classifier_repository" docs/a.md src/b.ts
classify_run "$classifier_repository"
expect_floor "classify: docs plus src is tier 1" 1 "$(floor_of)"
expect_equal "classify: docs side stays tier 0 in a mixed change" 0 "$(tier_of docs/a.md both)"
scratch_commit "$classifier_repository" docs/a.md src/b.ts package.json
classify_run "$classifier_repository"
expect_floor "classify: a manifest raises a docs and src change to tier 2" 2 "$(floor_of)"

# Output shape
jq -e '(.floorTier | IN(0, 1, 2)) and (.base | test("^[0-9a-f]{40}$")) and (.head | test("^[0-9a-f]{40}$")) and (.error == null)
  and (.unclassified | type == "array") and all(.paths[]; has("path") and has("side") and has("status") and has("tier") and (.reasons | type == "array" and length > 0))' <<<"$classify_output" >/dev/null
expect_equal "classify: output validates with jq -e" 0 "$?"
expect_equal "classify: base is the resolved main commit" "$(classify_git "$classifier_repository" rev-parse main)" "$(jq -r .base <<<"$classify_output")"
expect_equal "classify: head is the resolved scratch commit" "$(classify_git "$classifier_repository" rev-parse scratch)" "$(jq -r .head <<<"$classify_output")"
expect_equal "classify: stdout is a single JSON document" 1 "$(jq -s length <<<"$classify_output")"
expect_equal "classify: reasons name the rule" "tier2:dependency" "$(reasons_of package.json both)"

# Empty diff
classify_git "$classifier_repository" checkout -q -f -B scratch main
classify_run "$classifier_repository"
expect_equal "classify: empty diff is floor 0" 0 "$(floor_of)"
expect_equal "classify: empty diff has no paths" 0 "$(jq '.paths | length' <<<"$classify_output")"
expect_equal "classify: empty diff exits 0" 0 "$classify_status"

# Active work item bookkeeping
scratch_commit "$classifier_repository" .agents/specs/active/WORK-001.state.json .agents/specs/active/WORK-001.log.md
classify_run "$classifier_repository" --active WORK-001
expect_equal "active: own state and log only is floor 0" 0 "$(floor_of)"
expect_equal "active: state file tier is null" null "$(tier_of .agents/specs/active/WORK-001.state.json both)"
expect_equal "active: log file tier is null" null "$(tier_of .agents/specs/active/WORK-001.log.md both)"
expect_equal "active: bookkeeping reason" "active-item bookkeeping" "$(reasons_of .agents/specs/active/WORK-001.log.md both)"
classify_run "$classifier_repository"
expect_floor "active: without --active the same change is at least tier 1" ">=1" "$(floor_of)"
scratch_commit "$classifier_repository" .agents/specs/active/WORK-001.state.json src/b.ts
classify_run "$classifier_repository" --active WORK-001
expect_equal "active: bookkeeping plus src keeps the src tier" 1 "$(floor_of)"
scratch_commit "$classifier_repository" .agents/specs/active/WORK-001.state.json docs/a.md
classify_run "$classifier_repository" --active WORK-001
expect_equal "active: bookkeeping plus docs stays tier 0" 0 "$(floor_of)"
scratch_commit "$classifier_repository" .agents/specs/active/WORK-001.state.json .agents/specs/active/WORK-002.state.json
classify_run "$classifier_repository" --active WORK-001
expect_floor "active: another item's state is still at least tier 1" ">=1" "$(floor_of)"
scratch_commit "$classifier_repository" .agents/specs/active/WORK-001.state.json.bak
classify_run "$classifier_repository" --active WORK-001
expect_floor "active: a lookalike file name is not bookkeeping" ">=1" "$(floor_of)"
scratch_commit "$classifier_repository" .agents/specs/WORK-001.state.json
classify_run "$classifier_repository" --active WORK-001
expect_floor "active: the same name outside specs/active is not bookkeeping" ">=1" "$(floor_of)"
scratch_commit_line "$classifier_repository" .agents/specs/active/WORK-001.log.md "ran DROP TABLE users in the demo"
classify_run "$classifier_repository" --active WORK-001
expect_equal "active: destructive SQL words in the bookkeeping log do not raise the floor" 0 "$(floor_of)"
classify_git "$classifier_repository" checkout -q -f -B scratch main
mkdir -p "$classifier_repository/.agents/specs/active"
ln -s elsewhere "$classifier_repository/.agents/specs/active/WORK-001.state.json"
classify_git "$classifier_repository" add -A
classify_git "$classifier_repository" commit -q -m scratch
classify_run "$classifier_repository" --active WORK-001
expect_floor "active: a bookkeeping path that is a symlink is not exempt" ">=1" "$(floor_of)"

# Renames and deletions are classified on both sides
classify_git "$classifier_repository" checkout -q -f -B scratch main
mkdir -p "$classifier_repository/src"
classify_git "$classifier_repository" mv docs/a.md src/a.ts
classify_git "$classifier_repository" commit -q -m rename
classify_run "$classifier_repository"
expect_floor "rename: docs/a.md to src/a.ts is at least tier 1" ">=1" "$(floor_of)"
expect_equal "rename: old side is listed" 0 "$(tier_of docs/a.md old)"
expect_equal "rename: new side is listed" 1 "$(tier_of src/a.ts new)"
classify_git "$classifier_repository" checkout -q -f -B scratch main
classify_git "$classifier_repository" mv .github/workflows/x.yml docs/x.md
classify_git "$classifier_repository" commit -q -m rename
classify_run "$classifier_repository"
expect_equal "rename: a workflow renamed into docs is tier 2 on the old side" 2 "$(floor_of)"
classify_git "$classifier_repository" checkout -q -f -B scratch main
classify_git "$classifier_repository" rm -q .github/workflows/x.yml
classify_git "$classifier_repository" commit -q -m delete
classify_run "$classifier_repository"
expect_equal "delete: a deleted workflow is tier 2" 2 "$(floor_of)"
classify_git "$classifier_repository" checkout -q -f -B scratch main
classify_git "$classifier_repository" rm -q docs/a.md
classify_git "$classifier_repository" commit -q -m delete
classify_run "$classifier_repository"
expect_equal "delete: a deleted docs file is tier 0" 0 "$(floor_of)"
classify_git "$classifier_repository" checkout -q -f -B scratch main
classify_git "$classifier_repository" rm -q src/b.ts
classify_git "$classifier_repository" commit -q -m delete
classify_run "$classifier_repository"
expect_equal "delete: a deleted src file is tier 1" 1 "$(floor_of)"

# Destructive SQL in added lines of any file
while IFS='|' read -r expected_floor path_under_test sql_line; do
  [ -n "$expected_floor" ] || continue
  scratch_commit_line "$classifier_repository" "$path_under_test" "$sql_line"
  classify_run "$classifier_repository"
  expect_floor "sql: '$sql_line' in $path_under_test" "$expected_floor" "$(floor_of)"
done <<'SQL_CASES'
2|src/user.test.ts|await db.exec("DROP TABLE users");
2|src/user.test.ts|drop table if exists users;
2|src/x.ts|  Drop   Index  idx_a ON t;
2|src/x.ts|DROP COLUMN note
2|src/x.py|cursor.execute('TRUNCATE TABLE sessions')
2|src/x.sql.txt|TRUNCATE TABLE users;
2|src/x.sql.txt|TRUNCATE users;
2|src/x.sql.txt|truncate users
2|src/x.sql.txt|DROP SEQUENCE order_ids;
2|src/x.sql.txt|DROP TRIGGER IF EXISTS audit_row;
2|src/x.sql.txt|DROP FUNCTION f();
2|src/x.sql.txt|DROP PROCEDURE p;
2|src/x.ts|ALTER TABLE t ADD x int, DROP COLUMN y;
2|src/x.ts|DELETE FROM accounts
2|src/x.ts|DELETE FROM accounts WHERE id = 1
2|docs/runbook.md|run DROP DATABASE prod
2|src/x.sql.txt|TRUNCATE users CASCADE;
2|src/x.sql.txt|TRUNCATE ONLY users;
2|src/x.sql.txt|TRUNCATE users, orders;
2|src/x.ts|db.run("TRUNCATE users")
2|src/x.ts|run('truncate users', done)
2|src/x.sql.txt|DROP MATERIALIZED VIEW daily_totals;
2|src/x.sql.txt|DROP TEMPORARY TABLE scratch;
2|src/x.sql.txt|DROP TEMP TABLE scratch;
2|src/x.sql.txt|DROP TYPE mood;
2|src/x.sql.txt|DROP EXTENSION pgcrypto;
0|docs/prose.md|truncate long lines
0|docs/prose.md|truncate output lines when they are long
0|docs/prose.md|do not drop in type safety
0|docs/prose.md|grant access to the team
0|docs/prose.md|revoke the token
1|src/x.ts|GRANT ALL ON db TO app
1|src/x.ts|REVOKE select ON t FROM app
1|src/x.ts|text.truncate(80);
1|src/x.ts|const drop = tableName;
1|src/x.ts|// the dropped tables were archived
1|src/x.ts|dropTable();
1|src/x.ts|const grants = [];
1|src/x.ts|SELECT * FROM t
SQL_CASES
printf 'DROP TABLE users;\nexport const kept = 1;\n' >"$work_directory/old-with-drop.ts"
classify_git "$classifier_repository" checkout -q -f -B base-with-drop main
cp "$work_directory/old-with-drop.ts" "$classifier_repository/src/old.ts"
classify_git "$classifier_repository" add -A
classify_git "$classifier_repository" commit -q -m base-with-drop
printf 'export const kept = 1;\n' >"$classifier_repository/src/old.ts"
classify_git "$classifier_repository" add -A
classify_git "$classifier_repository" commit -q -m remove-drop
classify_output="$("$classifier" HEAD~1 HEAD "$classifier_repository")"
expect_equal "sql: only a removed DROP TABLE line does not raise the floor" 1 "$(floor_of)"
classify_git "$classifier_repository" checkout -q -f main
classify_git "$classifier_repository" branch -q -D base-with-drop
classify_git "$classifier_repository" checkout -q -f -B scratch main
printf '*.ts -diff\n' >"$classifier_repository/.gitattributes"
printf 'DROP TABLE users;\n' >"$classifier_repository/src/hidden.ts"
classify_git "$classifier_repository" add -A
classify_git "$classifier_repository" commit -q -m hidden
classify_run "$classifier_repository"
expect_equal "sql: a -diff attribute does not hide a destructive statement" 2 "$(floor_of)"
classify_git "$classifier_repository" checkout -q -f -B scratch main

# Unclassifiable changes raise the tier
classify_git "$classifier_repository" checkout -q -f -B scratch main
printf 'a\0b\n' >"$classifier_repository/src/blob.dat"
classify_git "$classifier_repository" add -A
classify_git "$classifier_repository" commit -q -m binary
classify_run "$classifier_repository"
expect_floor "unclassified: a binary file is at least tier 1" ">=1" "$(floor_of)"
expect_equal "unclassified: the binary file is listed" '["src/blob.dat"]' "$(jq -c .unclassified <<<"$classify_output")"
expect_equal "unclassified: binary reason" "unclassified:binary" "$(reasons_of src/blob.dat both)"
classify_git "$classifier_repository" checkout -q -f -B scratch main
printf 'a\0b\n' >"$classifier_repository/docs/image.png"
classify_git "$classifier_repository" add -A
classify_git "$classifier_repository" commit -q -m binary
classify_run "$classifier_repository"
expect_floor "unclassified: a binary file under docs is at least tier 1" ">=1" "$(floor_of)"
classify_git "$classifier_repository" checkout -q -f -B scratch main
ln -s ../etc/passwd "$classifier_repository/docs/link.md"
classify_git "$classifier_repository" add -A
classify_git "$classifier_repository" commit -q -m symlink
classify_run "$classifier_repository"
expect_floor "unclassified: a symlink named like docs is at least tier 1" ">=1" "$(floor_of)"
expect_equal "unclassified: symlink reason" "unclassified:symlink" "$(reasons_of docs/link.md both)"
classify_git "$classifier_repository" checkout -q -f -B scratch main
classify_git "$classifier_repository" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,vendor/lib
classify_git "$classifier_repository" commit -q -m submodule
classify_run "$classifier_repository"
expect_floor "unclassified: a submodule is at least tier 1" ">=1" "$(floor_of)"
expect_equal "unclassified: submodule reason" "unclassified:submodule" "$(reasons_of vendor/lib both)"
classify_git "$classifier_repository" config diff.ignoreSubmodules all
classify_run "$classifier_repository"
expect_floor "unclassified: diff.ignoreSubmodules config cannot hide a submodule" ">=1" "$(floor_of)"
classify_git "$classifier_repository" config --unset diff.ignoreSubmodules
classify_git "$classifier_repository" checkout -q -f -B scratch main
classify_git "$classifier_repository" config diff.noprefix true
scratch_commit_line "$classifier_repository" src/user.test.ts "DROP TABLE users;"
classify_run "$classifier_repository"
expect_equal "sql: attribution survives diff.noprefix config" "tier2:destructive-sql" "$(reasons_of src/user.test.ts both)"
classify_git "$classifier_repository" config --unset diff.noprefix

# Odd path names
scratch_commit "$classifier_repository" "docs/with space.md" "src/with space.ts"
classify_run "$classifier_repository"
expect_equal "paths: spaces are kept" 0 "$(tier_of 'docs/with space.md' both)"
expect_equal "paths: spaces in a src path" 1 "$(tier_of 'src/with space.ts' both)"
newline_name="docs/line
break.md"
scratch_commit "$classifier_repository" "$newline_name"
classify_run "$classifier_repository"
expect_equal "paths: a newline in a docs name round-trips" 0 "$(tier_of "$newline_name" both)"
expect_equal "paths: the newline name is one path" 1 "$(jq '.paths | length' <<<"$classify_output")"
newline_auth_name="src/auth
x.ts"
scratch_commit "$classifier_repository" "$newline_auth_name"
classify_run "$classifier_repository"
expect_equal "paths: a newline in an auth path is tier 2" 2 "$(floor_of)"
newline_workflow_name=".github/workflows/a
b.yml"
scratch_commit "$classifier_repository" "$newline_workflow_name"
classify_run "$classifier_repository"
expect_equal "paths: a newline in a workflow name is tier 2" 2 "$(floor_of)"
tab_name="docs/tab	name.md"
scratch_commit "$classifier_repository" "$tab_name"
classify_run "$classifier_repository"
expect_equal "paths: a tab in a docs name round-trips" 0 "$(tier_of "$tab_name" both)"
scratch_commit "$classifier_repository" "docs/caf$(printf '\303\251').md" 'docs/quote"d.md'
classify_run "$classifier_repository"
expect_equal "paths: non-ASCII and quotes in docs names are tier 0" 0 "$(floor_of)"
scratch_commit_line "$classifier_repository" 'src/q"uote.ts' "DROP TABLE users;"
classify_run "$classifier_repository"
expect_equal "paths: destructive SQL in a quoted-name file still raises the floor" 2 "$(floor_of)"

# Case-insensitive instruction files
scratch_commit "$classifier_repository" Docs/Skill.md plugins/p/Skills/S/skill.MD
classify_run "$classifier_repository"
expect_floor "case: odd-case skill markdown is at least tier 1" ">=1" "$(floor_of)"

# Case collisions fail closed to tier 2 (index entries only: the test filesystem may fold case)
printf 'x\n' >"$work_directory/collision-blob.txt"
collision_blob="$(classify_git "$classifier_repository" hash-object -w "$work_directory/collision-blob.txt")"
classify_git "$classifier_repository" checkout -q -f -B scratch main
classify_git "$classifier_repository" -c core.ignorecase=false update-index --add --cacheinfo "100644,$collision_blob,a.md"
classify_git "$classifier_repository" -c core.ignorecase=false update-index --add --cacheinfo "100644,$collision_blob,A.md"
classify_git "$classifier_repository" -c core.ignorecase=false commit -q -m collision
classify_run "$classifier_repository"
expect_equal "case: a head tree with a.md and A.md is floor 2" 2 "$(floor_of)"
expect_contains "case: the collision reason is recorded" "tier2:case-collision" "$(reasons_of A.md both)"
classify_git "$classifier_repository" checkout -q -f -B scratch main
classify_git "$classifier_repository" -c core.ignorecase=false update-index --add --cacheinfo "100644,$collision_blob,SRC/new.ts"
classify_git "$classifier_repository" -c core.ignorecase=false commit -q -m collision-directory
classify_run "$classifier_repository"
expect_equal "case: a path under SRC/ beside src/ is floor 2" 2 "$(floor_of)"
classify_git "$classifier_repository" checkout -q -f -B scratch main

# Plugin roots: code under a directory with .claude-plugin/plugin.json is tier 2
plugin_repository="$(new_repository plugin-repo main)"
mkdir -p "$plugin_repository/plugins/p/.claude-plugin" "$plugin_repository/plugins/p/skills/s" "$plugin_repository/plugins/p/scripts" "$plugin_repository/other/scripts"
printf '{}\n' >"$plugin_repository/plugins/p/.claude-plugin/plugin.json"
printf 'skill\n' >"$plugin_repository/plugins/p/skills/s/SKILL.md"
printf 'readme\n' >"$plugin_repository/plugins/p/README.md"
printf 'echo hi\n' >"$plugin_repository/plugins/p/scripts/guard-bash.sh"
printf 'echo hi\n' >"$plugin_repository/other/scripts/x.sh"
classify_git "$plugin_repository" add -A
classify_git "$plugin_repository" commit -q -m plugin
while IFS='|' read -r expected_floor path_under_test; do
  [ -n "$expected_floor" ] || continue
  scratch_commit "$plugin_repository" "$path_under_test"
  classify_run "$plugin_repository"
  expect_floor "plugin root: '$path_under_test'" "$expected_floor" "$(floor_of)"
done <<'PLUGIN_CASES'
2|plugins/p/scripts/guard-bash.sh
2|plugins/p/scripts/guard/rules.jq
2|plugins/p/agents/sub/x.md
2|plugins/p/.mcp.json
2|plugins/p/output-styles/style.md
2|plugins/p/lib/helper.ts
1|plugins/p/skills/s/SKILL.md
2|plugins/p/skills/s/helper.sh
2|plugins/p/skills/s/scripts/run.sh
2|plugins/p/skills/setup/templates/settings.json
2|plugins/p/commands/helper.sh
0|plugins/p/README.md
1|other/scripts/x.sh
PLUGIN_CASES
scratch_commit "$plugin_repository" plugins/p/scripts/guard-bash.sh
classify_run "$plugin_repository"
expect_equal "plugin root: the script reason is recorded" "tier2:plugin-code" "$(reasons_of plugins/p/scripts/guard-bash.sh both)"
scratch_commit "$plugin_repository" plugins/p/skills/s/SKILL.md
classify_run "$plugin_repository"
expect_equal "plugin root: a skill stays tier 1" 1 "$(tier_of plugins/p/skills/s/SKILL.md both)"
classify_git "$plugin_repository" checkout -q -f -B scratch main
classify_git "$plugin_repository" rm -q plugins/p/.claude-plugin/plugin.json
printf 'changed\n' >>"$plugin_repository/plugins/p/scripts/guard-bash.sh"
classify_git "$plugin_repository" add -A
classify_git "$plugin_repository" commit -q -m drop-plugin-json
classify_run "$plugin_repository"
expect_equal "plugin root: a root only in the base tree still counts" 2 "$(tier_of plugins/p/scripts/guard-bash.sh both)"
# Tier 0 never folds case: only the exact directory "docs/" qualifies (index entries, as the
# test filesystem folds case and the repository has no docs/ directory to collide with)
collision_blob="$(classify_git "$plugin_repository" hash-object -w "$work_directory/collision-blob.txt")"
for odd_docs_path in Docs/notes.txt DOCS/x.rst; do
  classify_git "$plugin_repository" checkout -q -f -B scratch main
  classify_git "$plugin_repository" -c core.ignorecase=false update-index --add --cacheinfo "100644,$collision_blob,$odd_docs_path"
  classify_git "$plugin_repository" -c core.ignorecase=false commit -q -m odd-docs
  classify_run "$plugin_repository"
  expect_equal "case: '$odd_docs_path' is not tier 0" 1 "$(floor_of)"
done
classify_git "$plugin_repository" checkout -q -f -B scratch main
scratch_commit "$classifier_repository" plugins/zz/.claude-plugin/plugin.json plugins/zz/scripts/x.sh
classify_run "$classifier_repository"
expect_equal "plugin root: a root only in the head tree still counts" 2 "$(tier_of plugins/zz/scripts/x.sh both)"

# Git environment hardening
scratch_commit "$classifier_repository" src/b.ts
scratch_sha="$(classify_git "$classifier_repository" rev-parse scratch)"
main_sha="$(classify_git "$classifier_repository" rev-parse main)"
classify_git "$classifier_repository" replace -f "$scratch_sha" "$main_sha"
classify_run "$classifier_repository"
expect_equal "hardening: a replace ref for the head commit does not hide the change" 1 "$(floor_of)"
expect_equal "hardening: the real path is listed under a replaced commit" 1 "$(tier_of src/b.ts both)"
classify_git "$classifier_repository" replace -d "$scratch_sha" >/dev/null
scratch_tree="$(classify_git "$classifier_repository" rev-parse "scratch^{tree}")"
main_tree="$(classify_git "$classifier_repository" rev-parse "main^{tree}")"
classify_git "$classifier_repository" replace -f "$scratch_tree" "$main_tree"
classify_run "$classifier_repository"
expect_equal "hardening: a replace ref for the head tree does not hide the change" 1 "$(tier_of src/b.ts both)"
classify_git "$classifier_repository" replace -d "$scratch_tree" >/dev/null

classify_git "$classifier_repository" checkout -q -f -B scratch main
printf 'a\0b\n' >"$classifier_repository/docs/image.png"
classify_git "$classifier_repository" add -A
classify_git "$classifier_repository" commit -q -m binary
printf 'docs/** diff\n' >"$classifier_repository/.gitattributes"
classify_run "$classifier_repository"
expect_floor "hardening: a worktree diff attribute does not make a docs binary tier 0" ">=1" "$(floor_of)"
rm -f "$classifier_repository/.gitattributes"
mkdir -p "$classifier_repository/.git/info"
: >"$classifier_repository/.git/info/attributes"
classify_run "$classifier_repository"
expect_equal "hardening: an empty info/attributes is fine" 0 "$classify_status"
printf 'docs/** diff\n' >"$classifier_repository/.git/info/attributes"
cp "$classifier_repository/.git/info/attributes" "$work_directory/attributes-before"
classify_run "$classifier_repository"
expect_equal "hardening: a non-empty info/attributes exits 3" 3 "$classify_status"
expect_equal "hardening: a non-empty info/attributes is floor 2" 2 "$(floor_of)"
expect_contains "hardening: the error names info/attributes" "info/attributes" "$(jq -r .error <<<"$classify_output")"
cmp -s "$work_directory/attributes-before" "$classifier_repository/.git/info/attributes"
expect_equal "hardening: info/attributes is left unchanged" 0 "$?"
rm -f "$classifier_repository/.git/info/attributes"
classify_git "$classifier_repository" checkout -q -f -B scratch main

# Renamed files are scanned in full: a statement shape moved out of docs/ is still seen
rename_repository="$(new_repository rename-repo main)"
mkdir -p "$rename_repository/docs"
for line_number in 1 2 3 4 5 6 7 8 9 10; do printf 'documentation line %s\n' "$line_number" >>"$rename_repository/docs/moved.md"; done
printf 'DROP TABLE users;\n' >>"$rename_repository/docs/moved.md"
classify_git "$rename_repository" add -A
classify_git "$rename_repository" commit -q -m seed
classify_git "$rename_repository" checkout -q -B scratch main
mkdir -p "$rename_repository/src"
classify_git "$rename_repository" mv docs/moved.md src/moved.ts
classify_git "$rename_repository" commit -q -m rename
classify_run "$rename_repository"
expect_equal "rename: a docs file with a statement shape renamed into src is floor 2" 2 "$(floor_of)"
expect_equal "rename: the new side carries the destructive reason" tier2:destructive-sql "$(reasons_of src/moved.ts new)"

# A mode change that makes a file executable raises the tier
classify_git "$classifier_repository" checkout -q -f -B scratch main
classify_git "$classifier_repository" update-index --chmod=+x docs/a.md
classify_git "$classifier_repository" commit -q -m executable
classify_run "$classifier_repository"
expect_equal "mode: making a docs file executable is tier 1" 1 "$(floor_of)"
expect_equal "mode: the executable reason is recorded" tier1:executable "$(reasons_of docs/a.md both)"
classify_git "$classifier_repository" checkout -q -f -B scratch main

# riskPaths, copyPaths and definedBy come from the base ref only
configured_repository="$(new_repository configured-repo main)"
mkdir -p "$configured_repository/.agents" "$configured_repository/marketing" "$configured_repository/src"
cat >"$configured_repository/.agents/gates.json" <<'JSON'
{"fast": "tests/run.sh", "full": {"command": "scripts/check.sh", "definedBy": ["scripts/run-all.sh"]},
 "riskPaths": {"2": ["src/payments/**", "standards/**"], "1": ["tools/**"]},
 "copyPaths": ["marketing/**", "**/*.md"],
 "definedBy": ["gate-check.sh", "config/**/*.cfg"]}
JSON
printf 'x\n' >"$configured_repository/marketing/page.html"
printf 'x\n' >"$configured_repository/src/b.ts"
classify_git "$configured_repository" add -A
classify_git "$configured_repository" commit -q -m config
while IFS='|' read -r expected_floor path_under_test; do
  [ -n "$expected_floor" ] || continue
  scratch_commit "$configured_repository" "$path_under_test"
  classify_run "$configured_repository"
  expect_floor "config: '$path_under_test'" "$expected_floor" "$(floor_of)"
done <<'CONFIG_CASES'
2|src/payments/charge.ts
2|standards/security.md
1|tools/build.sh
0|marketing/page.html
0|notes/anything.md
1|AGENTS.md
1|docs/CLAUDE.md
1|.agents/learnings/x.md
1|plugins/p/skills/s/SKILL.md
2|plugins/p/agents/a.md
2|.github/workflows/ci.yml
2|gate-check.sh
2|config/deep/x.cfg
2|scripts/run-all.sh
1|src/b.ts
1|gate-check.sh.bak
CONFIG_CASES
expect_equal "config: a riskPaths 2 reason is recorded" "riskPaths:2" "$(scratch_commit "$configured_repository" src/payments/a.ts; classify_run "$configured_repository"; reasons_of src/payments/a.ts both)"
expect_equal "config: a definedBy reason is recorded" "tier2:definedBy" "$(scratch_commit "$configured_repository" gate-check.sh; classify_run "$configured_repository"; reasons_of gate-check.sh both)"

# Values changed on the branch are ignored
classify_git "$configured_repository" checkout -q -f -B scratch main
cat >"$configured_repository/.agents/gates.json" <<'JSON'
{"fast": "tests/run.sh", "riskPaths": {"2": ["src/**"]}, "copyPaths": ["src/**", "marketing/**"], "definedBy": ["src/**"]}
JSON
printf 'y\n' >>"$configured_repository/src/b.ts"
printf 'y\n' >>"$configured_repository/marketing/page.html"
mkdir -p "$configured_repository/lib"
printf 'y\n' >"$configured_repository/lib/c.ts"
classify_git "$configured_repository" add -A
classify_git "$configured_repository" commit -q -m branch-config
classify_run "$configured_repository"
expect_equal "branch config: gates.json itself is tier 2" 2 "$(floor_of)"
expect_equal "branch config: a copyPaths added on the branch does not make src tier 0" 1 "$(tier_of src/b.ts both)"
expect_equal "branch config: base copyPaths still applies when the branch removes it" 0 "$(tier_of marketing/page.html both)"
expect_equal "branch config: a definedBy removed on the branch still applies from base" 0 "$(jq '[.paths[] | select(.path == "gate-check.sh")] | length' <<<"$classify_output")"
classify_git "$configured_repository" checkout -q -f -B scratch main
cat >"$configured_repository/.agents/gates.json" <<'JSON'
{"fast": "tests/run.sh", "riskPaths": {}, "copyPaths": [], "definedBy": []}
JSON
printf 'y\n' >>"$configured_repository/gate-check.sh"
printf 'y\n' >>"$configured_repository/src/payments.ts"
mkdir -p "$configured_repository/src/payments"
printf 'y\n' >>"$configured_repository/src/payments/a.ts"
classify_git "$configured_repository" add -A
classify_git "$configured_repository" commit -q -m branch-config
classify_run "$configured_repository"
expect_equal "branch config: riskPaths and definedBy emptied on the branch still apply from base" 2 "$(tier_of src/payments/a.ts both)"
expect_equal "branch config: definedBy emptied on the branch still applies from base" 2 "$(tier_of gate-check.sh both)"

# A classifier error is floor 2 with exit 3
broken_configuration_cases="$work_directory/broken-configurations.txt"
cat >"$broken_configuration_cases" <<'BROKEN'
not json at all
[]
null
"text"
{"riskPaths": []}
{"riskPaths": {"0": ["docs/**"]}}
{"riskPaths": {"2": "src/**"}}
{"riskPaths": {"2": [1]}}
{"riskPaths": null}
{"copyPaths": "docs/**"}
{"copyPaths": [""]}
{"definedBy": [1]}
{"definedBy": "x"}
{"full": {"definedBy": "x"}}
{"copyPaths": ["a\u0001b"]}
BROKEN
broken_index=0
while IFS= read -r broken_configuration; do
  broken_index=$((broken_index + 1))
  broken_repository="$(new_repository "broken-config-$broken_index" main)"
  mkdir -p "$broken_repository/.agents"
  printf '%s\n' "$broken_configuration" >"$broken_repository/.agents/gates.json"
  classify_git "$broken_repository" add -A
  classify_git "$broken_repository" commit -q -m config
  scratch_commit "$broken_repository" docs/a.md
  classify_run "$broken_repository"
  expect_equal "error: invalid gates.json ($broken_configuration) exits 3" 3 "$classify_status"
  expect_equal "error: invalid gates.json ($broken_configuration) is floor 2" 2 "$(floor_of)"
  expect_equal "error: invalid gates.json ($broken_configuration) sets error" true "$(jq '.error | type == "string" and length > 0' <<<"$classify_output")"
done <"$broken_configuration_cases"
broken_repository="$(new_repository broken-on-branch-only main)"
mkdir -p "$broken_repository/.agents"
printf '{"copyPaths": ["marketing/**"]}\n' >"$broken_repository/.agents/gates.json"
classify_git "$broken_repository" add -A
classify_git "$broken_repository" commit -q -m config
classify_git "$broken_repository" checkout -q -B scratch main
printf 'not json' >"$broken_repository/.agents/gates.json"
classify_git "$broken_repository" add -A
classify_git "$broken_repository" commit -q -m break
classify_run "$broken_repository"
expect_equal "error: malformed gates.json only on the branch is not a classifier error" 0 "$classify_status"
expect_equal "error: a malformed branch gates.json is itself tier 2" 2 "$(floor_of)"

"$classifier" no-such-ref HEAD "$classifier_repository" >"$work_directory/classify-out.json" 2>/dev/null
unknown_status=$?
expect_equal "error: unknown base ref exits 3" 3 "$unknown_status"
expect_equal "error: unknown base ref is floor 2" 2 "$(jq -r .floorTier "$work_directory/classify-out.json")"
expect_equal "error: unknown base ref sets error" true "$(jq '.error | type == "string"' "$work_directory/classify-out.json")"
"$classifier" HEAD no-such-ref "$classifier_repository" >"$work_directory/classify-out.json" 2>/dev/null
expect_equal "error: unknown head ref exits 3" 3 "$?"
expect_equal "error: unknown head ref is floor 2" 2 "$(jq -r .floorTier "$work_directory/classify-out.json")"
"$classifier" main scratch "$work_directory" >"$work_directory/classify-out.json" 2>/dev/null
expect_equal "error: a directory outside any repository exits 3" 3 "$?"
expect_equal "error: a directory outside any repository is floor 2" 2 "$(jq -r .floorTier "$work_directory/classify-out.json")"
"$classifier" 'main^{tree}' scratch "$classifier_repository" >"$work_directory/classify-out.json" 2>/dev/null
expect_equal "error: a tree is not a commit" 3 "$?"

# Usage errors
for usage_arguments in "" "main" "--active" "--active WORK-001" "--active WORK-1x main scratch" "--active work-001 main scratch" "--active WORK- main scratch" "--bogus main scratch" "main scratch dir extra" "--glob-match onlyone"; do
  # shellcheck disable=SC2086
  "$classifier" $usage_arguments >"$work_directory/classify-out.json" 2>"$work_directory/classify-stderr.txt"
  usage_status=$?
  expect_equal "usage: '$usage_arguments' exits 2" 2 "$usage_status"
  expect_equal "usage: '$usage_arguments' prints no JSON" "" "$(cat "$work_directory/classify-out.json")"
  expect_contains "usage: '$usage_arguments' explains on stderr" "usage:" "$(cat "$work_directory/classify-stderr.txt")"
done

# Caps (the environment can only lower them)
scratch_commit "$classifier_repository" docs/one.md docs/two.md docs/three.md
AI_ENGINEERING_CLASSIFY_MAX_PATHS=2 classify_run "$classifier_repository"
expect_equal "cap: more paths than the cap exits 0" 0 "$classify_status"
expect_equal "cap: more paths than the cap is floor 2" 2 "$(floor_of)"
expect_equal "cap: the reason is cap:exceeded" cap:exceeded "$(jq -r '.paths[0].reasons[0]' <<<"$classify_output")"
expect_equal "cap: error is null" null "$(jq -r '.error' <<<"$classify_output")"
AI_ENGINEERING_CLASSIFY_MAX_PATHS=3 classify_run "$classifier_repository"
expect_equal "cap: exactly the cap is not exceeded" 0 "$(floor_of)"
AI_ENGINEERING_CLASSIFY_MAX_PATHS=junk classify_run "$classifier_repository"
expect_equal "cap: a non-numeric override is ignored" 0 "$(floor_of)"
scratch_commit_line "$classifier_repository" src/big.ts "$(printf 'harmless line of added text %.0s\n' 1 2 3 4 5 6 7 8 9 10)"
AI_ENGINEERING_CLASSIFY_MAX_BYTES=100 classify_run "$classifier_repository"
expect_equal "cap: more diff bytes than the cap is floor 2" 2 "$(floor_of)"
expect_equal "cap: byte cap reason" cap:exceeded "$(jq -r '.paths[-1].reasons[0]' <<<"$classify_output")"
expect_equal "cap: byte cap is not an error exit" 0 "$classify_status"
classify_run "$classifier_repository"
expect_equal "cap: the same diff is fine under the default cap" 1 "$(floor_of)"
many_repository="$(new_repository many-paths main)"
classify_git "$many_repository" checkout -q -B scratch main
mkdir -p "$many_repository/docs"
many_index=0
while [ "$many_index" -lt 5001 ]; do
  : >"$many_repository/docs/f$many_index.md"
  many_index=$((many_index + 1))
done
classify_git "$many_repository" add -A
classify_git "$many_repository" commit -q -m many
AI_ENGINEERING_CLASSIFY_MAX_PATHS=999999 classify_run "$many_repository"
expect_equal "cap: an override cannot raise the path cap above 5000" 2 "$(floor_of)"
expect_equal "cap: above the default cap the output stays small" 1 "$(jq '.paths | length' <<<"$classify_output")"
classify_git "$many_repository" checkout -q -B scratch main
mkdir -p "$many_repository/docs"
many_index=0
while [ "$many_index" -lt 3000 ]; do
  : >"$many_repository/docs/f$many_index.md"
  many_index=$((many_index + 1))
done
classify_git "$many_repository" add -A
classify_git "$many_repository" commit -q -m many
classify_run "$many_repository"
expect_equal "cap: 3000 docs paths classify normally" 0 "$(floor_of)"
expect_equal "cap: 3000 docs paths are all listed" 3000 "$(jq '.paths | length' <<<"$classify_output")"

# Repository configuration cannot run programs or reshape the diff
classify_git "$classifier_repository" checkout -q -f -B scratch main
printf '#!/bin/sh\ntouch "%s/external-diff-ran"\n' "$work_directory" >"$work_directory/evil-diff.sh"
chmod +x "$work_directory/evil-diff.sh"
classify_git "$classifier_repository" config diff.external "$work_directory/evil-diff.sh"
classify_git "$classifier_repository" config diff.evil.textconv "$work_directory/evil-diff.sh"
printf '*.ts diff=evil\n' >"$classifier_repository/.gitattributes"
printf 'export const changed = 1;\n' >>"$classifier_repository/src/b.ts"
classify_git "$classifier_repository" add -A
classify_git "$classifier_repository" commit -q -m evil
classify_run "$classifier_repository"
expect_equal "safety: classification still works with hostile diff config" 1 "$(floor_of)"
expect_equal "safety: no external diff or textconv program ran" no "$([ -e "$work_directory/external-diff-ran" ] && echo yes || echo no)"
classify_git "$classifier_repository" config --unset diff.external
classify_git "$classifier_repository" config --unset diff.evil.textconv
classify_git "$classifier_repository" checkout -q -f main
rm -f "$classifier_repository/.gitattributes"

# ---------------------------------------------------------------- WORK-003 C2: hook command targets in the classifier
hook_repository="$(new_repository classifier-hooks main)"
mkdir -p "$hook_repository/.claude" "$hook_repository/scripts" "$hook_repository/tools" "$hook_repository/src"
cat >"$hook_repository/.claude/settings.json" <<'JSON'
{"hooks": {"PostToolUse": [{"matcher": "Edit", "hooks": [
  {"type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/format.sh --write && ./tools/lint.py; npx prettier $HOME/x.sh"}]}]},
 "statusLine": {"type": "command", "command": "src/status.sh"}}
JSON
printf 'echo format\n' >"$hook_repository/scripts/format.sh"
printf 'print(1)\n' >"$hook_repository/tools/lint.py"
printf 'echo status\n' >"$hook_repository/src/status.sh"
printf 'export const c = 1;\n' >"$hook_repository/src/c.ts"
classify_git "$hook_repository" add -A
classify_git "$hook_repository" commit -q -m seed
scratch_commit "$hook_repository" scripts/format.sh
classify_run "$hook_repository"
expect_floor "classify hooks: a base hook command target is tier 2" 2 "$(floor_of)"
expect_equal "classify hooks: reason names the hook target" "tier2:hook-target" "$(reasons_of scripts/format.sh both)"
scratch_commit "$hook_repository" tools/lint.py
classify_run "$hook_repository"
expect_equal "classify hooks: a ./-relative hook target is tier 2" "2 tier2:hook-target" "$(floor_of) $(reasons_of tools/lint.py both)"
scratch_commit "$hook_repository" src/c.ts
classify_run "$hook_repository"
expect_floor "classify hooks: an unreferenced file keeps its tier" 1 "$(floor_of)"
scratch_commit "$hook_repository" src/status.sh
classify_run "$hook_repository"
expect_floor "classify hooks: a statusLine command is not a hook target" 1 "$(floor_of)"
# Only the base settings count: a hook added on the branch does not name its own target.
classify_git "$hook_repository" checkout -q -f -B scratch main
jq '.hooks.PreToolUse = [{"matcher": "Bash", "hooks": [{"type": "command", "command": "src/c.ts"}]}]' "$hook_repository/.claude/settings.json" >"$work_directory/branch-settings.json"
cp "$work_directory/branch-settings.json" "$hook_repository/.claude/settings.json"
printf 'changed\n' >>"$hook_repository/src/c.ts"
classify_git "$hook_repository" add -A
classify_git "$hook_repository" commit -q -m scratch
classify_run "$hook_repository"
expect_equal "classify hooks: a branch-only hook does not mark its target" "1" "$(tier_of src/c.ts both)"
# Case variants match, as for the built-in rules.
case_repository="$(new_repository classifier-hooks-case main)"
mkdir -p "$case_repository/.claude" "$case_repository/scripts"
printf '%s\n' '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "Scripts/Format.sh"}]}]}}' >"$case_repository/.claude/settings.json"
printf 'echo\n' >"$case_repository/scripts/format.sh"
classify_git "$case_repository" add -A
classify_git "$case_repository" commit -q -m seed
scratch_commit "$case_repository" scripts/format.sh
classify_run "$case_repository"
expect_equal "classify hooks: a case variant of a hook target is tier 2" "2" "$(tier_of scripts/format.sh both)"
# A malformed base settings file is a classifier error, never a silent pass.
malformed_repository="$(new_repository classifier-hooks-malformed main)"
mkdir -p "$malformed_repository/.claude" "$malformed_repository/src"
printf '{"hooks": [}\n' >"$malformed_repository/.claude/settings.json"
printf 'x\n' >"$malformed_repository/src/a.ts"
classify_git "$malformed_repository" add -A
classify_git "$malformed_repository" commit -q -m seed
scratch_commit "$malformed_repository" src/a.ts
classify_run "$malformed_repository"
expect_equal "classify hooks: malformed base settings is a classifier error" "3 2" "$classify_status $(floor_of)"
classify_git "$malformed_repository" checkout -q -f main
printf '%s\n' '{"hooks": []}' >"$malformed_repository/.claude/settings.json"
classify_git "$malformed_repository" commit -q -am "hooks array"
scratch_commit "$malformed_repository" src/a.ts
classify_run "$malformed_repository"
expect_equal "classify hooks: a non-object hooks value is a classifier error" "3 2" "$classify_status $(floor_of)"

# ---------------------------------------------------------------- WORK-003 C1: release consistency check
version_check() { bash "$repository_directory/scripts/check-doc-versions.sh" "$@"; }
new_version_fixture() {
  local directory="$work_directory/versions-$1"
  mkdir -p "$directory/versions" "$directory/docs/nested"
  printf '# Changelog\n\n## 0.3.0\nUnreleased.\n\n## 0.2.0\nReleased.\n' >"$directory/versions/CHANGELOG.md"
  printf '%s\n' "$directory"
}

fixture="$(new_version_fixture none)"
printf 'No pinned versions here.\n' >"$fixture/README.md"
version_output="$(version_check "$fixture" 2>&1)"; version_status=$?
expect_equal "release check: no references passes" 0 "$version_status"

fixture="$(new_version_fixture known)"
printf 'claude plugin marketplace add asholiver/ai-engineering-system@v0.2.0\n' >"$fixture/README.md"
printf '{"source": {"ref": "v0.3.0"}}\n' >"$fixture/docs/nested/setup.md"
version_output="$(version_check "$fixture" 2>&1)"; version_status=$?
expect_equal "release check: known versions in both shapes pass" 0 "$version_status"

fixture="$(new_version_fixture unknown-at)"
printf 'line one\nasholiver/ai-engineering-system@v9.9.9\n' >"$fixture/README.md"
version_output="$(version_check "$fixture" 2>&1)"; version_status=$?
expect_equal "release check: unknown @ reference fails" 1 "$version_status"
expect_contains "release check: reports file, line and version" "README.md:2: version 9.9.9" "$version_output"

fixture="$(new_version_fixture unknown-ref)"
printf '{"ref": "v1.2.3"}\n' >"$fixture/README.md"
version_output="$(version_check "$fixture" 2>&1)"; version_status=$?
expect_equal "release check: unknown ref reference fails" 1 "$version_status"

# check.sh wiring: an unknown pin must fail the gate. check.sh runs this suite, so its
# documentation version step is run in isolation instead of running check.sh recursively.
doc_versions_step="$(grep -E '^bash scripts/check-doc-versions\.sh ' "$repository_directory/scripts/check.sh")"
expect_equal "check.sh: exactly one documentation version step" 1 "$(printf '%s\n' "$doc_versions_step" | grep -c .)"
# shellcheck disable=SC2016 # `$repository_directory` and `$doc_versions_fixture` are names inside the step text
step_root_text='$repository_directory' fixture_root_text='$doc_versions_fixture'
fixture_step="${doc_versions_step//"$step_root_text"/$fixture_root_text}"
gate_failures="$(
  cd "$repository_directory" || exit 1
  failures=0
  # shellcheck disable=SC2329 # invoked by the evaluated check.sh step
  check_failed() { failures=$((failures + 1)); }
  # shellcheck disable=SC2034 # read by the evaluated check.sh step
  doc_versions_fixture="$fixture"
  eval "$fixture_step" >/dev/null 2>&1
  echo "$failures"
)"
expect_equal "check.sh: an unknown pinned version fails the gate" 1 "$gate_failures"

fixture="$(new_version_fixture unknown-nested)"
printf 'clean\n' >"$fixture/README.md"
printf 'text\n{"ref": "v4.0.0"}\n' >"$fixture/docs/nested/guide.md"
version_output="$(version_check "$fixture" 2>&1)"; version_status=$?
expect_equal "release check: unknown version in nested docs file fails" 1 "$version_status"
expect_contains "release check: reports nested path" "docs/nested/guide.md:2: version 4.0.0" "$version_output"

fixture="$(new_version_fixture prerelease-unknown)"
printf 'asholiver/ai-engineering-system@v0.2.0-rc1\n' >"$fixture/README.md"
version_output="$(version_check "$fixture" 2>&1)"; version_status=$?
expect_equal "release check: a -rc1 pin without a changelog entry fails" 1 "$version_status"
expect_contains "release check: the full pre-release token is reported" "version 0.2.0-rc1 has no entry" "$version_output"
printf '\n## 0.2.0-rc1\nCandidate.\n' >>"$fixture/versions/CHANGELOG.md"
version_output="$(version_check "$fixture" 2>&1)"; version_status=$?
expect_equal "release check: a -rc1 pin with its changelog entry passes" 0 "$version_status"

fixture="$(new_version_fixture unreadable)"
printf '{"ref": "v0.2.0"}\n' >"$fixture/docs/nested/secret.md"
if [ "$(id -u)" = "0" ]; then
  echo "note: skipping the unreadable-file release check (running as root)"
else
  chmod 000 "$fixture/docs/nested/secret.md"
  version_output="$(version_check "$fixture" 2>&1)"; version_status=$?
  chmod 644 "$fixture/docs/nested/secret.md"
  expect_equal "release check: an unreadable docs file fails the check" 1 "$version_status"
  expect_contains "release check: the read failure is explained" "grep failed" "$version_output"
fi

# ---------------------------------------------------------------- WORK-002 B1: workstate.sh
# The transition script for work-item state. State is a workflow record, not security authority:
# these tests also prove that the guard does not read it.
workstate="$scripts/workstate.sh"
ws_directory="$work_directory/workstate-specs"
mkdir -p "$ws_directory"
# Starting an increment verifies its base against origin/<default>, so the specs directory is a
# repository with a default-branch ref (no remote is contacted).
git -C "$ws_directory" init -q -b main
git -C "$ws_directory" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m base
git -C "$ws_directory" update-ref refs/remotes/origin/main HEAD
git -C "$ws_directory" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
ws_base="$(git -C "$ws_directory" rev-parse HEAD)"
ws_counter=0
ws_id=""
ws_output=""
ws_status=0

ws() { "$workstate" --dir "$ws_directory" "$@"; }
run_ws() { ws_output="$(ws "$@" 2>&1)"; ws_status=$?; }
state_path() { printf '%s/%s.state.json' "$ws_directory" "${1:-$ws_id}"; }
state_value() { jq -r "$1" "$(state_path "${2:-}")"; }
state_checksum() { cksum <"$(state_path "${1:-}")"; }
file_sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
expect_ws() { # label expected-exit
  expect_equal "$1: exit code" "$2" "$ws_status"
}
write_spec() { printf '# %s test spec\n## Status\nDraft\n## Objective\nTest.\n%s' "$1" "${2:-}" >"$ws_directory/$1.md"; }

# Creates a fresh work item driven to the given status, with one increment (I1, tier 1).
new_item() { # status [spec text appended, e.g. a delivery policy section]
  ws_counter=$((ws_counter + 1))
  ws_id="WORK-$((100 + ws_counter))"
  write_spec "$ws_id" "${2:-}"
  ws create "$ws_id" >/dev/null || fail "setup: create $ws_id"
  ws increment-add "$ws_id" --inc I1 --title One --tier 1 >/dev/null || fail "setup: increment-add $ws_id"
  [ "$1" = proposed ] && return 0
  ws approve "$ws_id" spec --owner-command approve >/dev/null || fail "setup: approve $ws_id"
  [ "$1" = approved ] && return 0
  ws deliver "$ws_id" --owner-command deliver >/dev/null || fail "setup: deliver $ws_id"
  case "$1" in
    delivering) ;;
    blocked) ws block "$ws_id" --trigger 2 --question "which?" --options a,b >/dev/null || fail "setup: block $ws_id" ;;
    paused) ws pause "$ws_id" >/dev/null || fail "setup: pause $ws_id" ;;
    done | archived)
      ws increment-set "$ws_id" --inc I1 --status active --base-sha "$ws_base" >/dev/null || fail "setup: increment active"
      ws increment-set "$ws_id" --inc I1 --status ready >/dev/null || fail "setup: increment ready"
      ws increment-set "$ws_id" --inc I1 --status merged --merge-sha abc1234 >/dev/null || fail "setup: increment merged"
      ws "done" "$ws_id" >/dev/null || fail "setup: done"
      [ "$1" = archived ] && { ws archive "$ws_id" >/dev/null || fail "setup: archive"; }
      ;;
  esac
  return 0
}

# --- create and basic validation
write_spec WORK-090
run_ws create WORK-090
expect_ws "workstate create" 0
expect_equal "workstate create: status proposed" proposed "$(state_value .status WORK-090)"
expect_equal "workstate create: schemaVersion" 1 "$(state_value .schemaVersion WORK-090)"
expect_equal "workstate create: spec hash is the SHA-256 of the spec file" "$(file_sha256 "$ws_directory/WORK-090.md")" "$(state_value .spec.contentSha256 WORK-090)"
expect_equal "workstate create: no approval and no delivery" "null null" "$(state_value '[.approval, .delivery] | map(tostring) | join(" ")' WORK-090)"
expect_equal "workstate create: history records it with a timestamp" "create->proposed true" "$(state_value '.history[0] | "\(.transition) \(.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))"' WORK-090)"
run_ws create WORK-090
expect_ws "workstate create twice is an invalid transition" 3
run_ws create WORK-091
expect_ws "workstate create without a spec is refused" 3
run_ws create work-1
expect_ws "workstate: a malformed work id is a usage error" 2
run_ws frobnicate WORK-090
expect_ws "workstate: an unknown command is a usage error" 2
run_ws show WORK-090 --bogus x
expect_ws "workstate: an unknown option is a usage error" 2
run_ws approve WORK-090 spec --owner-command approve --by "$(printf 'a\001b')"
expect_ws "workstate: control characters in text are refused" 2
run_ws show WORK-090
expect_ws "workstate show" 0
expect_equal "workstate show prints the state as JSON" WORK-090 "$(jq -r .id <<<"$ws_output")"
run_ws status WORK-090
expect_equal "workstate status: summary reports the spec hash still matches" "proposed" "$(jq -r .status <<<"$ws_output")"
run_ws show WORK-199
expect_ws "workstate show: no state is a schema-class error" 5

# --- transition table: allowed transitions, actors and approvals
new_item proposed
run_ws approve "$ws_id" spec --owner-command approve --by Tester
expect_ws "allowed: proposed -> approved" 0
expect_equal "approved: status" approved "$(state_value .status)"
expect_equal "approved: owner-command source, command, approver" "owner-command approve Tester" "$(state_value '"\(.approval.source) \(.approval.command) \(.approval.by)"')"
expect_equal "approved: records the spec hash" "$(file_sha256 "$ws_directory/$ws_id.md")" "$(state_value .approval.specSha256)"
expect_equal "approved: records the time" true "$(state_value '.approval.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")')"
run_ws deliver "$ws_id" --owner-command deliver --by Tester
expect_ws "allowed: approved -> authorised -> delivering" 0
expect_equal "delivering: status" delivering "$(state_value .status)"
expect_equal "delivering: owner-command delivery record" "owner-command deliver Tester" "$(state_value '"\(.delivery.source) \(.delivery.command) \(.delivery.by)"')"
expect_equal "delivering: delivery spec hash equals the approved hash" "$(state_value .approval.specSha256)" "$(state_value .delivery.specSha256)"
expect_equal "delivering: both delivery steps are in history" "approved->authorised authorised->delivering" "$(state_value '.history[-2:] | map(.transition) | join(" ")')"
run_ws block "$ws_id" --trigger 2 --question "pick a library" --options "a,b"
expect_ws "allowed: delivering -> blocked" 0
expect_equal "blocked: decision has trigger, options, asked time and no answer" "2 2 true null" "$(state_value '.decisions[0] | "\(.trigger) \(.options | length) \(.askedAt != null) \(.answeredAt)"')"
run_ws answer "$ws_id" --decision D1 --answer "use a"
expect_ws "allowed: blocked -> delivering by a conversation answer (trigger 2)" 0
expect_equal "answered: source is conversation and the answer is recorded verbatim" "conversation use a delivering" "$(state_value '"\(.decisions[0].source) \(.decisions[0].answer) \(.status)"')"
run_ws pause "$ws_id" --actor owner
expect_ws "allowed: delivering -> paused" 0
expect_equal "paused: remembers where it was paused from" "paused delivering" "$(state_value '"\(.status) \(.pausedFrom)"')"
run_ws deliver "$ws_id" --owner-command deliver
expect_ws "allowed: paused -> delivering by resume" 0
expect_equal "resumed: back to the paused-from status" "delivering null" "$(state_value '"\(.status) \(.pausedFrom)"')"
run_ws increment-set "$ws_id" --inc I1 --status active --base-sha "$ws_base"
run_ws increment-set "$ws_id" --inc I1 --status ready
run_ws "done" "$ws_id"
expect_ws "done is refused while an increment is not merged" 3
run_ws increment-set "$ws_id" --inc I1 --status merged
expect_ws "merged without a merge sha is refused" 3
run_ws increment-set "$ws_id" --inc I1 --status merged --merge-sha abc1234
run_ws "done" "$ws_id"
expect_ws "allowed: delivering -> done (every increment merged)" 0
run_ws archive "$ws_id"
expect_ws "allowed: done -> archived" 0
expect_equal "archived: status" archived "$(state_value .status)"

new_item blocked
run_ws pause "$ws_id"
expect_ws "allowed: blocked -> paused" 0
run_ws deliver "$ws_id" --owner-command deliver
expect_ws "resume a paused-from-blocked item" 0
expect_equal "resume returns to blocked, not delivering" blocked "$(state_value .status)"

# E2 (WORK-002 E2E): a request that only adds scope is an open proposal, not a block.
new_item delivering
run_ws propose "$ws_id" --question "add a CHANGELOG.md?" --options "amend-spec,separate-item"
expect_ws "propose: a scope proposal is recorded while delivering" 0
expect_equal "propose: delivery continues (status unchanged)" delivering "$(state_value .status)"
expect_equal "propose: open trigger-1 decision marked not blocking" "D1 1 false null 2" "$(state_value '.decisions[0] | "\(.id) \(.trigger) \(.blocking) \(.answeredAt) \(.options | length)"')"
expect_equal "propose: history records it as not blocking" "scope proposal recorded (trigger 1, not blocking)" "$(state_value '.history[-1].transition')"
run_ws readiness "$ws_id"
expect_equal "propose: readiness lists the open proposal" "D1 1 false" "$(jq -r '.openDecisions[0] | "\(.id) \(.trigger) \(.blocking)"' <<<"$ws_output")"
run_ws status "$ws_id"
expect_equal "propose: status counts the open decision" 1 "$(jq -r .openDecisions <<<"$ws_output")"
run_ws evidence "$ws_id" --inc I1 --kind gate --result pass
expect_ws "propose: approved work still records progress with the proposal open" 0
run_ws answer "$ws_id" --decision D1 --answer "separate work item"
expect_ws "propose: an open proposal can be answered while delivering" 0
expect_equal "propose: the answer is recorded and the status is unchanged" "delivering conversation separate work item" "$(state_value '"\(.status) \(.decisions[0].source) \(.decisions[0].answer)"')"
run_ws answer "$ws_id" --decision D1 --answer "again"
expect_ws "propose: an answered proposal cannot be answered again" 3
run_ws readiness "$ws_id"
expect_equal "propose: an answered proposal leaves the open list" 0 "$(jq -r '.openDecisions | length' <<<"$ws_output")"
run_ws propose "$ws_id" --trigger 3 --question "accept the risk?"
expect_ws "propose: a trigger other than 1 is a usage error" 2
run_ws propose "$ws_id" --question ""
expect_ws "propose: a question is required" 2
run_ws propose "$ws_id" --question "1"$'\n'"2"
expect_ws "propose: control characters in the question are refused" 2
# An open proposal never unblocks a blocked item, and a blocking decision is not answered outside blocked.
new_item delivering
ws propose "$ws_id" --question "add docs?" >/dev/null
ws block "$ws_id" --trigger 2 --question "which library?" --options a,b >/dev/null
run_ws answer "$ws_id" --decision D1 --answer "later"
expect_ws "propose: answering a proposal while blocked is allowed" 0
expect_equal "propose: answering a proposal does not unblock" blocked "$(state_value .status)"
run_ws answer "$ws_id" --decision D2 --answer "a"
expect_equal "propose: answering the blocking decision resumes delivery" delivering "$(state_value .status)"
expect_equal "block: decisions from block are marked blocking" true "$(state_value '.decisions[1].blocking')"
new_item blocked
ws pause "$ws_id" >/dev/null
run_ws answer "$ws_id" --decision D1 --answer "a"
expect_ws "a blocking decision cannot be answered while paused" 3
expect_equal "the paused item stays paused" paused "$(state_value .status)"
new_item delivering
printf 'changed\n' >>"$ws_directory/$ws_id.md"
run_ws propose "$ws_id" --question "add docs?"
expect_ws "propose: a spec change since approval stops the proposal" 6

# Security re-check M1: an earlier answered owner decision never resumes a later block.
new_item delivering
ws finding-add "$ws_id" --finding F1 --source qa --severity low --summary "s" >/dev/null
ws approve "$ws_id" accept F1 --owner-command approve >/dev/null
ws block "$ws_id" --trigger 3 --question "waive a security control?" >/dev/null
run_ws answer "$ws_id" --decision D1
expect_ws "M1: an earlier owner decision cannot resume a new trigger-3 block" 3
expect_equal "M1: the item stays blocked on the trigger-3 decision" "blocked null" "$(state_value '"\(.status) \(.decisions[1].answeredAt)"')"
run_ws deliver "$ws_id" --owner-command deliver
expect_ws "M1: deliver cannot resume a block whose own decision is unanswered" 3
expect_equal "M1: still blocked after the refused deliver" blocked "$(state_value .status)"
new_item delivering
ws finding-add "$ws_id" --finding F1 --source qa --severity low --summary "s" >/dev/null
ws approve "$ws_id" accept F1 --owner-command approve >/dev/null
ws block "$ws_id" --trigger 5 --question "which reading?" --options a,b >/dev/null
run_ws answer "$ws_id" --decision D1 --answer "a"
expect_ws "M1: an earlier owner decision cannot resume a trigger-5 block" 3
expect_equal "M1: the trigger-5 block stays open" "blocked null" "$(state_value '"\(.status) \(.decisions[1].answeredAt)"')"
run_ws deliver "$ws_id" --owner-command deliver
expect_ws "M1: deliver cannot resume a trigger-5 block" 3
run_ws answer "$ws_id" --decision D2 --answer "a"
expect_ws "M1: the blocking decision itself resumes delivery" 0
expect_equal "M1: delivering after the right answer" delivering "$(state_value .status)"

# E2 re-test defect 1: /approve with --decision, then /deliver, resumes a trigger-3 block.
new_item delivering
ws finding-add "$ws_id" --finding F1 --source security-reviewer --severity low --summary "overflow" --security >/dev/null
ws block "$ws_id" --trigger 3 --question "defer F1?" --options defer,accept >/dev/null
run_ws deliver "$ws_id" --owner-command deliver
expect_ws "resume: deliver is refused before the owner answers the trigger-3 decision" 3
expect_contains "resume: the refusal names the open decision" "blocked on decision D1" "$ws_output"
run_ws approve "$ws_id" defer F1 --decision D1 --owner-command approve
expect_ws "resume: the owner answers through approve with --decision" 0
expect_equal "resume: approve records the answer but does not change status" blocked "$(state_value .status)"
run_ws deliver "$ws_id"
expect_ws "resume: deliver without the owner-command marker is refused" 4
run_ws deliver "$ws_id" --owner-command deliver
expect_ws "resume: deliver resumes the blocked item after the owner's decision" 0
expect_equal "resume: delivering, recorded as an owner-command resume" "delivering blocked->delivering (resumed after owner decision D1) owner-command:deliver" "$(state_value '"\(.status) \(.history[-1].transition) \(.history[-1].actor)"')"
run_ws deliver "$ws_id" --owner-command deliver
expect_ws "resume: deliver on a delivering item is still refused" 3
new_item delivering
ws finding-add "$ws_id" --finding F1 --source qa --severity low --summary "s" >/dev/null
ws block "$ws_id" --trigger 3 --question "defer F1?" >/dev/null
ws approve "$ws_id" defer F1 --decision D1 --owner-command approve >/dev/null
printf 'changed\n' >>"$ws_directory/$ws_id.md"
run_ws deliver "$ws_id" --owner-command deliver
expect_ws "resume: a spec change since approval stops the resume" 6
expect_equal "resume: the item is proposed again" proposed "$(state_value .status)"

# E2 re-test defect 2: record a head SHA without a status change.
new_item delivering
ws increment-set "$ws_id" --inc I1 --status active --base-sha "$ws_base" >/dev/null
active_at_before="$(state_value '.increments[0].activeAt')"
run_ws increment-set "$ws_id" --inc I1 --status active --base-sha "$ws_base" --head-sha abc1234
expect_ws "head sha: repeating the current status records fields only" 0
expect_equal "head sha: recorded, still active, not ready" "abc1234 active null" "$(state_value '.increments[0] | "\(.headSha) \(.status) \(.readyAt)"')"
expect_equal "head sha: activeAt unchanged" "$active_at_before" "$(state_value '.increments[0].activeAt')"
expect_equal "head sha: history shows no status change" "increment I1 updated" "$(state_value '.history[-1].transition')"
run_ws increment-set "$ws_id" --inc I1 --head-sha def5678
expect_ws "head sha: recorded with no --status" 0
expect_equal "head sha: the newer sha replaces it" "def5678 active" "$(state_value '.increments[0] | "\(.headSha) \(.status)"')"
run_ws increment-set "$ws_id" --inc I1
expect_ws "head sha: increment-set with nothing to record is a usage error" 2
run_ws increment-set "$ws_id" --inc I1 --head-sha "not-a-sha"
expect_ws "head sha: a malformed sha is refused" 2
ws increment-set "$ws_id" --inc I1 --status ready >/dev/null
ready_at_before="$(state_value '.increments[0].readyAt')"
run_ws increment-set "$ws_id" --inc I1 --status ready --head-sha 0123abc
expect_equal "head sha: ready -> ready keeps readyAt" "0 $ready_at_before ready" "$ws_status $(state_value '.increments[0] | "\(.readyAt) \(.status)"')"
ws increment-set "$ws_id" --inc I1 --status merged --merge-sha abc1234 >/dev/null
run_ws increment-set "$ws_id" --inc I1 --status merged --merge-sha def5678
expect_ws "head sha: merged -> merged stays refused" 3
# Security re-check L-A: a merged record is final; a merge SHA comes only with the move to merged.
merged_before="$(state_checksum)"
run_ws increment-set "$ws_id" --inc I1 --merge-sha def5678
expect_ws "L-A: a merged increment's merge sha cannot be rewritten" 3
run_ws increment-set "$ws_id" --inc I1 --head-sha def5678
expect_ws "L-A: a merged increment's head sha cannot be rewritten" 3
run_ws increment-set "$ws_id" --inc I1 --pr 99 --branch other
expect_ws "L-A: a merged increment's pr and branch cannot be rewritten" 3
expect_equal "L-A: refused updates leave the merged record unchanged" "$merged_before" "$(state_checksum)"
new_item delivering
ws increment-set "$ws_id" --inc I1 --status active --base-sha "$ws_base" >/dev/null
run_ws increment-set "$ws_id" --inc I1 --merge-sha abc1234
expect_ws "L-A: a merge sha cannot be recorded on an active increment" 3
ws increment-set "$ws_id" --inc I1 --status ready >/dev/null
run_ws increment-set "$ws_id" --inc I1 --status ready --merge-sha abc1234
expect_ws "L-A: a merge sha cannot be recorded on a ready increment" 3
expect_equal "L-A: no merge sha recorded before the merge" null "$(state_value '.increments[0].mergeSha')"
run_ws increment-set "$ws_id" --inc I1 --status merged
expect_ws "L-A: merged still needs a merge sha" 3
run_ws increment-set "$ws_id" --inc I1 --status merged --merge-sha abc1234
expect_ws "L-A: the merge sha is recorded with the move to merged" 0
expect_equal "L-A: merged with its sha" "merged abc1234" "$(state_value '.increments[0] | "\(.status) \(.mergeSha)"')"

# Security re-check I1: decisions without a blocking field count as blocking, never as proposals.
new_item delivering
ws propose "$ws_id" --question "add docs?" >/dev/null
jq 'del(.decisions[0].blocking)' "$(state_path)" >"$work_directory/legacy-state.json" && mv "$work_directory/legacy-state.json" "$(state_path)"
run_ws answer "$ws_id" --decision D1 --answer "later"
expect_ws "I1: a decision with no blocking field is not answerable as a proposal" 3
run_ws readiness "$ws_id"
expect_equal "I1: readiness reports it as blocking" true "$(jq -r '.openDecisions[0].blocking' <<<"$ws_output")"

# Disallowed transitions: every one fails with exit 3 and changes nothing.
while IFS='|' read -r target command_line; do
  [ -n "$target" ] || continue
  new_item "$target"
  before="$(state_checksum)"
  read -r command_word command_rest <<<"$command_line"
  # shellcheck disable=SC2086 # command_rest is a deliberate word-split argument list
  run_ws "$command_word" "$ws_id" $command_rest
  expect_ws "disallowed from $target: $command_line" 3
  expect_equal "disallowed from $target leaves state unchanged: $command_line" "$before" "$(state_checksum)"
done <<'CASES'
proposed|deliver --owner-command deliver
proposed|block --trigger 1 --question q
proposed|answer --decision D1 --answer x
proposed|pause
proposed|done
proposed|archive
proposed|approve revoke --owner-command approve
proposed|raise-tier --inc I1 --tier 2
proposed|finding-add --finding F1 --source qa --severity low --summary s
proposed|increment-set --inc I1 --status active
approved|approve spec --owner-command approve
approved|block --trigger 1 --question q
approved|pause
approved|done
approved|archive
approved|increment-add --inc I2 --title Two --tier 0
approved|finding-add --finding F1 --source qa --severity low --summary s
delivering|approve spec --owner-command approve
delivering|deliver --owner-command deliver
delivering|answer --decision D1 --answer x
proposed|propose --question q
approved|propose --question q
blocked|propose --question q
paused|propose --question q
done|propose --question q
delivering|archive
delivering|increment-add --inc I2 --title Two --tier 0
blocked|deliver --owner-command deliver
blocked|block --trigger 1 --question q
blocked|done
blocked|approve spec --owner-command approve
paused|approve spec --owner-command approve
paused|block --trigger 1 --question q
paused|pause
paused|done
paused|answer --decision D1 --answer x
done|approve spec --owner-command approve
done|deliver --owner-command deliver
done|block --trigger 1 --question q
done|pause
done|done
done|finding-add --finding F1 --source qa --severity low --summary s
archived|archive
archived|done
archived|deliver --owner-command deliver
archived|approve revoke --owner-command approve
CASES

# --- owner commands
# Owner-only transitions without the marker are refused with exit 4 and never change state.
while IFS='|' read -r target command_line; do
  [ -n "$target" ] || continue
  new_item "$target"
  ws finding-add "$ws_id" --finding F1 --source qa --severity low --summary s >/dev/null 2>&1
  before="$(state_checksum)"
  read -r command_word command_rest <<<"$command_line"
  # shellcheck disable=SC2086 # command_rest is a deliberate word-split argument list
  run_ws "$command_word" "$ws_id" $command_rest
  expect_ws "no owner command: $target $command_line" 4
  expect_contains "no owner command: the message says it is not security authority" "not security authority" "$ws_output"
  expect_equal "no owner command leaves state unchanged: $target $command_line" "$before" "$(state_checksum)"
done <<'CASES'
proposed|approve spec
approved|deliver
paused|deliver
delivering|approve accept F1
delivering|approve defer F1
delivering|approve tier I1 0
delivering|approve revoke
blocked|approve revoke
delivering|approve accept F1 --owner-command deliver
delivering|approve tier I1 0 --owner-command deliver
delivering|approve revoke --owner-command deliver
proposed|approve spec --owner-command deliver
approved|deliver --owner-command approve
paused|deliver --owner-command approve
approved|deliver --owner-command bogus
CASES

new_item delivering
run_ws show "$ws_id" --owner-command approve
expect_ws "the owner marker is refused on non-owner commands" 2

# Every approve sub-action maps to its owner-only transition and records the owner command.
new_item delivering
ws finding-add "$ws_id" --finding F1 --source qa --severity high --summary one >/dev/null
ws finding-add "$ws_id" --finding F2 --source qa --severity low --summary two >/dev/null
run_ws approve "$ws_id" accept F1 --owner-command approve --note "accepted: cosmetic"
expect_ws "approve accept" 0
# shellcheck disable=SC2016 # `$d` and `$x` are jq variables inside the single-quoted program
expect_equal "approve accept: finding disposition links an owner-command decision" "owner accept D1 owner-command 3" "$(state_value '.findings[0].disposition as $d | .decisions[0] as $x | "\($d.state) \($d.action) \($d.decisionId) \($x.source) \($x.trigger)"')"
run_ws approve "$ws_id" defer F2 --owner-command approve
expect_ws "approve defer" 0
expect_equal "approve defer: disposition action" "owner defer" "$(state_value '.findings[1].disposition | "\(.state) \(.action)"')"
run_ws approve "$ws_id" accept F1 --owner-command approve
expect_ws "approve accept on a finding that is no longer open is refused" 3
run_ws approve "$ws_id" tier I1 2 --owner-command approve
expect_ws "approve tier cannot raise a tier" 3
run_ws approve "$ws_id" tier I1 0 --owner-command approve
expect_ws "approve tier lowers a tier" 0
expect_equal "approve tier: tier lowered, proposed tier kept" "0 1" "$(state_value '.increments[0] | "\(.tier) \(.proposedTier)"')"
run_ws raise-tier "$ws_id" --inc I1 --tier 2
expect_ws "raise-tier (coordinator) raises a tier with no marker" 0
run_ws raise-tier "$ws_id" --inc I1 --tier 1
expect_ws "raise-tier cannot lower a tier" 3
run_ws approve "$ws_id" revoke --owner-command approve
expect_ws "approve revoke" 0
expect_equal "approve revoke: back to proposed with no approval or delivery" "proposed null null" "$(state_value '"\(.status) \(.approval) \(.delivery)"')"
expect_equal "approve revoke is recorded in history as an owner-command transition" "owner-command:approve" "$(state_value '.history[-1].actor')"
run_ws approve "$ws_id" revoke --owner-command approve
expect_ws "approve revoke on a proposed item is refused" 3

# A trigger-3 decision needs the owner's approve command before delivery resumes.
new_item delivering
ws finding-add "$ws_id" --finding F1 --source qa --severity high --summary one >/dev/null
run_ws block "$ws_id" --trigger 3 --question "accept the risk?"
run_ws answer "$ws_id" --decision D1 --answer yes
expect_ws "a trigger-3 decision cannot be answered from conversation" 4
expect_equal "refused answer leaves the item blocked" blocked "$(state_value .status)"
run_ws approve "$ws_id" accept F1 --decision D1 --owner-command approve
expect_ws "approve accept resolves the open trigger-3 decision" 0
expect_equal "the item is still blocked until the answer step" "blocked owner-command" "$(state_value '"\(.status) \(.decisions[0].source)"')"
run_ws answer "$ws_id" --decision D1
expect_ws "answer resumes after the owner decided" 0
expect_equal "answer: delivering again" delivering "$(state_value .status)"
run_ws decision "$ws_id" --trigger 3 --question q --answer a
expect_ws "a trigger-3 decision cannot be recorded from conversation" 4
run_ws decision "$ws_id" --trigger 1 --question "also update the README?" --answer "not in approved scope; continuing"
expect_ws "a trigger-1 conversation decision is recorded without a status change" 0
expect_equal "decision: recorded as conversation, status unchanged" "conversation delivering" "$(state_value '"\(.decisions[-1].source) \(.status)"')"

# approve can never authorise or resume delivery; pausing does not let approve resume either.
new_item paused
run_ws approve "$ws_id" spec --owner-command approve
expect_ws "approve cannot resume a paused item" 3
new_item approved
run_ws approve "$ws_id" revoke --owner-command deliver
expect_ws "deliver cannot revoke" 4
expect_equal "refused deliver-as-revoke leaves the item approved" approved "$(state_value .status)"

# --- intent / implementation boundary
# (a) Words in a conversation create no approval: nothing but the owner command moves a proposed item.
new_item proposed
printf '\nWe also need to update the README.\n' >>"$ws_directory/$ws_id.md"
run_ws check "$ws_id"
expect_ws "boundary (a): a spec edit on a proposed item is not an error" 0
expect_equal "boundary (a): the item stays proposed with no approval" "proposed null" "$(state_value '"\(.status) \(.approval)"')"
run_ws deliver "$ws_id" --owner-command deliver
expect_ws "boundary (a): deliver preconditions refuse a proposed item" 3
expect_equal "boundary (a): still proposed after the refused deliver" proposed "$(state_value .status)"
# (b) During delivering, a spec edit changes the hash; the next transition returns to proposed.
new_item delivering
approved_hash="$(state_value .approval.specSha256)"
printf '\nAdd a README requirement.\n' >>"$ws_directory/$ws_id.md"
expect_equal "boundary (b): the edit changes the spec hash" "different" "$([ "$approved_hash" = "$(file_sha256 "$ws_directory/$ws_id.md")" ] && echo same || echo different)"
run_ws status "$ws_id"
expect_equal "boundary (b): status (read-only) reports the mismatch and does not write" "false delivering" "$(jq -r '"\(.specMatchesApproval) \(.status)"' <<<"$ws_output")"
run_ws finding-add "$ws_id" --finding F1 --source qa --severity low --summary s
expect_ws "boundary (b): the next transition detects the spec change (exit 6)" 6
expect_equal "boundary (b): the item is back to proposed with approval and delivery cleared" "proposed null null" "$(state_value '"\(.status) \(.approval) \(.delivery)"')"
expect_equal "boundary (b): history records the spec change" "delivering->proposed (spec changed)" "$(state_value '.history[-1].transition')"
run_ws block "$ws_id" --trigger 1 --question q
expect_ws "boundary (b): delivery stays stopped" 3
new_item approved
printf '\nChanged.\n' >>"$ws_directory/$ws_id.md"
run_ws deliver "$ws_id" --owner-command deliver
expect_ws "boundary: deliver after a spec change is refused with the spec-hash exit code" 6
expect_equal "boundary: and the item is proposed again" proposed "$(state_value .status)"
new_item paused
printf '\nChanged.\n' >>"$ws_directory/$ws_id.md"
run_ws deliver "$ws_id" --owner-command deliver
expect_ws "boundary: resuming a paused item after a spec change is refused" 6
expect_equal "boundary: the paused item is proposed" proposed "$(state_value .status)"
new_item delivering
rm -f "$ws_directory/$ws_id.md"
run_ws check "$ws_id"
expect_ws "boundary: a missing spec stops delivery (exit 6) without rewriting state" 6

# --- policy validation
policy_case() { # label expected-exit policy-text [expected substring]
  new_item proposed "$3"
  run_ws approve "$ws_id" spec --owner-command approve
  expect_ws "policy: $1" "$2"
  if [ "$2" != 0 ]; then
    expect_equal "policy: $1 leaves the item proposed" proposed "$(state_value .status)"
    [ -z "${4:-}" ] || expect_contains "policy: $1 message" "$4" "$ws_output"
  fi
}
policy_case "ephemeralDeploy is rejected with a pointer to WORK-004" 7 $'## Delivery policy\n- ephemeralDeploy: true\n' "WORK-004"
policy_case "persistentEnvironments is rejected with a pointer to WORK-004" 7 $'## Delivery policy\npersistentEnvironments: staging\n' "WORK-004"
policy_case "a production deploy entry is rejected" 7 $'## Delivery policy\n- productionDeploy: true\n' "WORK-004"
policy_case "a deploy entry naming production is rejected" 7 $'## Delivery policy\n- deploy: production\n' "WORK-004"
policy_case "a release entry is rejected" 7 $'## Delivery policy\n- `release`: true\n' "WORK-004"
policy_case "an unknown field is rejected" 7 $'## Delivery policy\n- retries: 3\n' "unknown delivery policy field"
policy_case "an invalid boolean is rejected" 7 $'## Delivery policy\n- pushWorkBranch: maybe\n' "pushWorkBranch must be true or false"
policy_case "an invalid pull request mode is rejected" 7 $'## Delivery policy\n- openPullRequest: merge\n' "openPullRequest must be"
policy_case "a duplicate field is rejected" 7 $'## Delivery policy\n- pushWorkBranch: true\n- pushWorkBranch: false\n' "twice"
policy_case "a pull request without a pushed branch is rejected" 7 $'## Delivery policy\n- pushWorkBranch: false\n' "requires pushWorkBranch"
policy_case "a deployment field after other sections is still found" 7 $'## Delivery policy\n- pushWorkBranch: true\n\n## Other\nx\n## Delivery policy\n- ephemeralDeploy: true\n' "WORK-004"
policy_case "no policy section means defaults" 0 ""
policy_case "a prose line in the policy section is rejected" 7 $'## Delivery policy\nPush the branch and then relax.\n' "unrecognised line"
policy_case "a prose line naming deploy is rejected" 7 $'## Delivery policy\nNothing is deployed from this work item.\n' "WORK-004"
policy_case "bold deployment key is rejected (L4)" 7 $'## Delivery policy\n- **ephemeralDeploy**: true\n' "WORK-004"
policy_case "hyphenated environments key is rejected (L4)" 7 $'## Delivery policy\n- persistent-environments: staging\n' "WORK-004"
policy_case "free-text production deploy line is rejected (L4)" 7 $'## Delivery policy\n- Production deploy: allowed\n' "WORK-004"
policy_case "comments in the policy section are allowed" 0 $'## Delivery policy\n<!-- deployment fields are rejected -->\n- pushWorkBranch: true\n'
policy_case "a multi-line comment is allowed" 0 $'## Delivery policy\n<!-- one\ndeploy two -->\n- openPullRequest: draft\n'
policy_case "policy fields outside the policy section are not read" 0 $'## Notes\n- ephemeralDeploy: true\n'
new_item proposed
ws approve "$ws_id" spec --owner-command approve >/dev/null
ws deliver "$ws_id" --owner-command deliver >/dev/null
expect_equal "policy defaults copied at delivery" "true true ready" "$(state_value '.delivery.policy | "\(.pushWorkBranch) \(.openPullRequest) \(.pullRequestMode)"')"
new_item delivering $'## Delivery policy\n- `pushWorkBranch`: true\n- `openPullRequest`: draft\n'
expect_equal "policy: a draft pull request is copied at delivery" "true true draft" "$(state_value '.delivery.policy | "\(.pushWorkBranch) \(.openPullRequest) \(.pullRequestMode)"')"
new_item delivering $'## Delivery policy\n- pushWorkBranch: false\n- openPullRequest: false\n'
expect_equal "policy: pushing and pull requests can be switched off" "false false null" "$(state_value '.delivery.policy | "\(.pushWorkBranch) \(.openPullRequest) \(.pullRequestMode)"')"

# --- records and metrics
new_item delivering
run_ws increment-set "$ws_id" --inc I1 --status ready
expect_ws "an increment cannot skip from planned to ready" 3
run_ws increment-set "$ws_id" --inc I1 --status active --branch feature/x --base-sha "$ws_base"
expect_ws "increment planned -> active" 0
run_ws increment-recovery "$ws_id" --inc I1
run_ws increment-recovery "$ws_id" --inc I1
expect_equal "recoveries are counted" 2 "$(state_value '.increments[0].recoveries')"
run_ws evidence "$ws_id" --inc I1 --kind gate --result pass --note "fast gate"
expect_ws "gate evidence is recorded" 0
run_ws evidence "$ws_id" --inc I1 --kind review --result fail
expect_equal "evidence entries are kept" "gate pass review fail" "$(state_value '.increments[0].evidence | map("\(.kind) \(.result)") | join(" ")')"
run_ws evidence "$ws_id" --inc I1 --kind nonsense --result pass
expect_ws "evidence kind is validated" 2
run_ws owner-action-add "$ws_id" --action-id A1 --description "gh auth login" --increment I1
expect_ws "an owner action is declared" 0
run_ws owner-action-done "$ws_id" --action-id A1
expect_ws "an owner action is completed" 0
run_ws owner-action-done "$ws_id" --action-id A1
expect_ws "an owner action cannot be completed twice" 3
run_ws finding-add "$ws_id" --finding F1 --source qa --severity medium --summary "non-security"
run_ws finding-add "$ws_id" --finding F2 --source security-reviewer --severity high --summary "security" --security
run_ws finding-invalid "$ws_id" --finding F1 --evidence "reproduced: not an issue"
expect_ws "a non-security finding can be recorded invalid with evidence" 0
run_ws finding-invalid "$ws_id" --finding F2 --evidence "looks fine"
expect_ws "a security finding cannot be recorded invalid without the reviewer's confirmation" 3
run_ws finding-invalid "$ws_id" --finding F2 --evidence "retested" --confirmed-by security-reviewer
expect_ws "a security finding can be recorded invalid with the raising reviewer's confirmation" 0
run_ws finding-fixed "$ws_id" --finding F1 --sha abc1234
expect_ws "a finding that is not open cannot be fixed" 3
run_ws finding-add "$ws_id" --finding F3 --source qa --severity critical --summary "fix me" --security
run_ws finding-fixed "$ws_id" --finding F3 --sha abc1234
expect_ws "a security finding can be fixed inside intent at any severity" 0
expect_equal "finding fixed carries the sha" "fixed abc1234" "$(state_value '.findings[2].disposition | "\(.state) \(.sha)"')"
run_ws increment-set "$ws_id" --inc I1 --status ready --head-sha def5678
run_ws increment-set "$ws_id" --inc I1 --status merged --merge-sha 0123abc --pr 12
expect_equal "metrics: increment active, ready and merged timestamps" "true true true" "$(state_value '.increments[0] | "\(.activeAt != null) \(.readyAt != null) \(.mergedAt != null)"')"
expect_equal "metrics: owner action requested and done times" "true true" "$(state_value '.ownerActions[0] | "\(.requestedAt != null) \(.doneAt != null)"')"
expect_equal "metrics: every history entry has a time, transition and actor" "true" "$(state_value '.history | all(.at != null and .transition != null and .actor != null)')"

# --- atomic, validated writes; corrupt state is never repaired
new_item proposed
printf '{ not json' >"$(state_path)"
before="$(state_checksum)"
run_ws approve "$ws_id" spec --owner-command approve
expect_ws "corrupt state: refused with the schema exit code" 5
expect_contains "corrupt state: the message says it is not repaired" "not valid JSON" "$ws_output"
expect_equal "corrupt state is left exactly as found" "$before" "$(state_checksum)"
run_ws show "$ws_id"
expect_ws "corrupt state: show also reports the schema error" 5
new_item proposed
jq '.status = "levitating"' "$(state_path)" >"$work_directory/bad-status.json"
cp "$work_directory/bad-status.json" "$(state_path)"
run_ws pause "$ws_id"
expect_ws "an unknown status fails schema validation" 5
new_item delivering
jq '.increments[0].worktreeBranches = "work/x"' "$(state_path)" >"$work_directory/bad-worktrees.json"
cp "$work_directory/bad-worktrees.json" "$(state_path)"
run_ws status "$ws_id"
expect_ws "worktree branches that are not a list of names fail schema validation" 5
new_item delivering
run_ws increment-worktree "$ws_id" --inc I1 --branch work/WORK-1-I1-T1
expect_ws "increment-worktree records a worktree branch" 0
expect_equal "increment-worktree: the branch is listed" '["work/WORK-1-I1-T1"]' "$(state_value '.increments[0].worktreeBranches' | jq -c .)"
run_ws increment-worktree "$ws_id" --inc I1 --branch work/WORK-1-I1-T1
expect_ws "increment-worktree: a branch is recorded only once" 3
# shellcheck disable=SC2016 # the literal text $(id) is an injection-shaped branch name under test
for bad_branch in "work/../x" "work//x" "-x" "work/x.lock" "work/.x" "work x" 'work/$(id)'; do
  run_ws increment-worktree "$ws_id" --inc I1 --branch "$bad_branch"
  expect_ws "increment-worktree: refuses branch '$bad_branch'" 2
done
run_ws evidence "$ws_id" --inc I1 --kind review --reviewer qa --result pass --sha abc1234
expect_equal "evidence: reviewer and sha are recorded" "qa abc1234" "$(state_value '.increments[0].evidence[-1] | "\(.reviewer) \(.sha)"')"
run_ws evidence "$ws_id" --inc I1 --kind gate --reviewer qa --result pass
expect_ws "evidence: a reviewer applies only to review evidence" 2
run_ws evidence "$ws_id" --inc I1 --kind review --reviewer external --result pass
expect_ws "evidence: external review is never recorded as review evidence" 2
run_ws evidence "$ws_id" --inc I1 --kind residual-risks --result pass --sha "not a sha"
expect_ws "evidence: a malformed sha is refused" 2
# The base an increment starts from (WORK-003 C2, H1): required at planned -> active, a full
# commit id equal to origin/<default> at that moment, and never recorded later or changed.
new_item delivering
before="$(state_checksum)"
run_ws increment-set "$ws_id" --inc I1 --status active --branch work/WORK-1-I1
expect_ws "base: starting an increment without a base is refused" 2
run_ws increment-set "$ws_id" --inc I1 --status active --branch work/WORK-1-I1 --base-sha "${ws_base:0:12}"
expect_ws "base: a short base is refused" 2
run_ws increment-set "$ws_id" --inc I1 --status active --branch work/WORK-1-I1 --base-sha 2222222222222222222222222222222222222222
expect_ws "base: a base other than origin/<default> is refused" 3
expect_contains "base: the refusal names origin/<default>" "is not the current origin/<default> commit ($ws_base)" "$ws_output"
expect_equal "base: refused starts leave the state unchanged" "$before" "$(state_checksum)"
git -C "$ws_directory" symbolic-ref --delete refs/remotes/origin/HEAD
run_ws increment-set "$ws_id" --inc I1 --status active --branch work/WORK-1-I1 --base-sha "$ws_base"
expect_ws "base: no origin/HEAD means the base cannot be verified" 3
git -C "$ws_directory" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
first_base="$ws_base"
run_ws increment-set "$ws_id" --inc I1 --status active --branch work/WORK-1-I1 --base-sha "$(printf '%s' "$first_base" | tr 'a-f' 'A-F')"
expect_ws "base: recorded when the increment starts (case-insensitive input)" 0
expect_equal "base: stored in lower case" "$first_base" "$(state_value '.increments[0].baseSha')"
run_ws increment-set "$ws_id" --inc I1 --base-sha "$first_base"
expect_ws "base: repeating the same base is allowed" 0
before="$(state_checksum)"
run_ws increment-set "$ws_id" --inc I1 --base-sha 2222222222222222222222222222222222222222
expect_ws "base: a different base is refused" 3
expect_contains "base: the refusal says a base is never replaced" "a recorded base is never replaced" "$ws_output"
expect_equal "base: the state is unchanged" "$before" "$(state_checksum)"
# Path A (late recording): an increment started before this rule, with no base, never gets one.
new_item delivering
jq '.increments[0].status = "active" | .increments[0].activeAt = "2000-01-01T00:00:00Z"' "$(state_path)" >"$work_directory/no-base.json"
cp "$work_directory/no-base.json" "$(state_path)"
run_ws increment-set "$ws_id" --inc I1 --base-sha "$ws_base"
expect_ws "base: a base cannot be recorded after the increment started" 3
expect_equal "base: still no base" null "$(state_value '.increments[0].baseSha')"
for bad_branch in HEAD origin/main refs/heads/x remotes/origin/x tags/v1; do
  run_ws increment-worktree "$ws_id" --inc I1 --branch "$bad_branch"
  expect_ws "increment-worktree: refuses the ref-like name '$bad_branch'" 2
done

# --- a jq program that cannot run is never read as "valid" or "false" (WORK-003 C2 review).
# A stand-in jq on PATH fails only the calls whose program contains a marker, from the Nth such
# call on; every other call runs the real jq.
jq_stand_in="$work_directory/jq-stand-in"
jq_call_count="$work_directory/jq-stand-in-count"
mkdir -p "$jq_stand_in"
cat >"$jq_stand_in/jq" <<STANDIN
#!/bin/bash
for argument in "\$@"; do
  case "\$argument" in
    *"\$JQ_FAIL_MARKER"*)
      count=\$((\$(cat "\$JQ_CALL_COUNT") + 1))
      echo "\$count" >"\$JQ_CALL_COUNT"
      [ "\$count" -lt "\$JQ_FAIL_FROM" ] || exit 3
      ;;
  esac
done
exec "$(command -v jq)" "\$@"
STANDIN
chmod +x "$jq_stand_in/jq"
run_ws_failing_jq() { # marker first-failing-call workstate-arguments...
  local marker="$1" first_failing="$2"
  shift 2
  printf '0\n' >"$jq_call_count"
  ws_output="$(PATH="$jq_stand_in:$PATH" JQ_FAIL_MARKER="$marker" JQ_FAIL_FROM="$first_failing" JQ_CALL_COUNT="$jq_call_count" "$workstate" --dir "$ws_directory" "$@" 2>&1)"
  ws_status=$?
}
expect_equal "jq stand-in: the validator marker is defined once in workstate.sh" 1 "$(grep -c 'def each_of' "$workstate")"
# shellcheck disable=SC2016 # the literal jq text $f is searched for, not expanded
expect_equal "jq stand-in: the security-finding rule marker appears once in workstate.sh" 1 "$(grep -c 'any(.id == \$f and .security)' "$workstate")"
new_item delivering
before="$(state_checksum)"
run_ws_failing_jq each_of 1 status "$ws_id"
expect_ws "validator cannot run at load: a schema error, never a pass" 5
expect_contains "validator cannot run at load: says so" "the schema validator could not run" "$ws_output"
expect_equal "validator cannot run at load: the stand-in was reached" 1 "$(cat "$jq_call_count")"
run_ws_failing_jq each_of 2 evidence "$ws_id" --inc I1 --kind gate --result pass
expect_ws "validator cannot run at write: the write is refused" 5
expect_contains "validator cannot run at write: refusal" "refusing to write" "$ws_output"
expect_contains "validator cannot run at write: says so" "the schema validator could not run" "$ws_output"
expect_equal "validator cannot run: the state is not modified" "$before" "$(state_checksum)"
expect_equal "validator cannot run: no temporary state file is left" "" "$(find "$ws_directory" -name ".$ws_id.*" | head -n 1)"
run_ws_failing_jq each_of 99 evidence "$ws_id" --inc I1 --kind gate --result pass
expect_ws "validator control: the stand-in alone changes nothing" 0
run_ws finding-add "$ws_id" --finding F1 --source security-reviewer --severity high --summary "security" --security
before="$(state_checksum)"
run_ws_failing_jq 'and .security)' 1 finding-invalid "$ws_id" --finding F1 --evidence "looks fine"
expect_ws "a security-finding rule that cannot run stops finding-invalid" 1
expect_contains "the rule failure is reported" "a state rule could not be evaluated" "$ws_output"
expect_equal "the security finding stays open" "$before open" "$(state_checksum) $(state_value '.findings[0].disposition.state')"
run_ws_failing_jq 'and .security)' 99 finding-invalid "$ws_id" --finding F1 --evidence "looks fine"
expect_ws "control: without --confirmed-by the security finding is still refused" 3
new_item proposed
jq '.approval = {"by": "x"}' "$(state_path)" >"$work_directory/bad-approval.json"
cp "$work_directory/bad-approval.json" "$(state_path)"
run_ws show "$ws_id"
expect_ws "an approval on a proposed item fails schema validation" 5
new_item proposed
jq '.id = "WORK-777"' "$(state_path)" >"$work_directory/bad-id.json"
cp "$work_directory/bad-id.json" "$(state_path)"
run_ws show "$ws_id"
expect_ws "a state file naming a different work item is refused" 5
new_item proposed
chmod 000 "$(state_path)"
if [ "$(id -u)" = "0" ]; then
  echo "note: skipping the unreadable-state check (running as root)"
else
  run_ws show "$ws_id"
  expect_ws "unreadable state is a schema-class failure" 5
fi
chmod 644 "$(state_path)"
leftovers="$(find "$ws_directory" -name '.WORK-*' | wc -l | tr -d ' ')"
expect_equal "no temp or lock files are left behind" 0 "$leftovers"
new_item proposed
mkdir "$ws_directory/.$ws_id.lock"
lock_probe_status=0
"$workstate" --dir "$ws_directory" check "$ws_id" >/dev/null 2>&1 || lock_probe_status=$?
rm -rf "$ws_directory/.$ws_id.lock"
expect_equal "a held lock is a bounded wait that ends in an environment error" 1 "$lock_probe_status"

# --- v0.2 import
import_directory="$work_directory/import-specs"
mkdir -p "$import_directory"
import_ws() { "$workstate" --dir "$import_directory" "$@"; }
legacy_sections=$'## Implementation state\n- T1 done: tests pass\n## Review state\n- reviewed: no findings\n'
printf '# Draft item\n## Status\nDraft\n## Objective\nx\n%s' "$legacy_sections" >"$import_directory/WORK-010.md"
printf '# Approved item\n## Status\nApproved (by Ashley Oliver, 2026-10-06), in principle.\n## Objective\nx\n%s' "$legacy_sections" >"$import_directory/WORK-011.md"
printf '# Partial item\n## Status\n**Approved** (by Ashley Oliver, 2026-09-01)\n## Objective\nx\n%s' "$legacy_sections" >"$import_directory/WORK-012.md"
printf '# Bare approved\n## Status\nApproved\n## Objective\nx\n' >"$import_directory/WORK-013.md"
printf '# In progress\n## Status\nIn progress\n## Objective\nx\n' >"$import_directory/WORK-014.md"
printf '# No status\n## Objective\nx\n' >"$import_directory/WORK-015.md"
import_state() { jq -r "$1" "$import_directory/$2.state.json"; }

spec_before="$(file_sha256 "$import_directory/WORK-010.md")"
output="$(import_ws import WORK-010 2>&1)"; status_code=$?
expect_equal "import Draft: exit code" 0 "$status_code"
expect_equal "import Draft: becomes proposed with no approval" "proposed null null" "$(import_state '"\(.status) \(.approval) \(.delivery)"' WORK-010)"
expect_equal "import Draft: the spec file is untouched, legacy sections included" "$spec_before" "$(file_sha256 "$import_directory/WORK-010.md")"

spec_before="$(file_sha256 "$import_directory/WORK-011.md")"
output="$(import_ws import WORK-011 2>&1)"; status_code=$?
expect_equal "import Approved: exit code" 0 "$status_code"
expect_equal "import Approved: status approved, never authorised or delivering" approved "$(import_state .status WORK-011)"
expect_equal "import Approved: approval is imported, with approver and date from the Status line" "imported Ashley Oliver 2026-10-06T00:00:00Z" "$(import_state '"\(.approval.source) \(.approval.by) \(.approval.at)"' WORK-011)"
expect_equal "import Approved: the approval records the current spec hash" "$(file_sha256 "$import_directory/WORK-011.md")" "$(import_state .approval.specSha256 WORK-011)"
expect_equal "import Approved: no delivery record" null "$(import_state .delivery WORK-011)"
expect_equal "import Approved: legacy sections and the spec are untouched" "$spec_before" "$(file_sha256 "$import_directory/WORK-011.md")"
expect_contains "import Approved: legacy Implementation state still in the spec" "## Implementation state" "$(cat "$import_directory/WORK-011.md")"
state_before="$(cksum <"$import_directory/WORK-011.state.json")"
output="$(import_ws import WORK-011 2>&1)"; status_code=$?
expect_equal "import is idempotent: second run exit code" 0 "$status_code"
expect_equal "import is idempotent: state is byte-identical" "$state_before" "$(cksum <"$import_directory/WORK-011.state.json")"
output="$(import_ws deliver WORK-011 2>&1)"; status_code=$?
expect_equal "an imported approval needs the owner command to deliver" 4 "$status_code"
output="$(import_ws deliver WORK-011 --owner-command deliver 2>&1)"; status_code=$?
expect_equal "an imported approval cannot be delivered (L3)" 3 "$status_code"
output="$(import_ws approve WORK-011 spec --owner-command approve 2>&1)"; status_code=$?
expect_equal "approve spec re-approves an imported approval" 0 "$status_code"
output="$(import_ws deliver WORK-011 --owner-command deliver 2>&1)"; status_code=$?
expect_equal "after a fresh owner approval the item can be delivered by the owner command" 0 "$status_code"
expect_equal "delivery after import is recorded as an owner-command delivery" "owner-command" "$(import_state .delivery.source WORK-011)"

output="$(import_ws import WORK-012 --merged "F0-S0|Foundation|1|abc1234def" --merged "F0-S1|Auth|2|def5678abc|1" 2>&1)"; status_code=$?
expect_equal "import with merged history: exit code" 0 "$status_code"
expect_equal "import with merged history: increments recorded as merged, unknown tier is the highest" "F0-S0 merged 1 abc1234def 2|F0-S1 merged 2 def5678abc 1" "$(import_state '.increments | map("\(.id) \(.status) \(.pr) \(.mergeSha) \(.tier)") | join("|")' WORK-012)"
expect_equal "import with merged history: still approved, not delivering" approved "$(import_state .status WORK-012)"
state_before="$(cksum <"$import_directory/WORK-012.state.json")"
output="$(import_ws import WORK-012 --merged "F0-S0|Foundation|1|abc1234def" --merged "F0-S1|Auth|2|def5678abc|1" 2>&1)"; status_code=$?
expect_equal "import with merged history is idempotent" "0 $state_before" "$status_code $(cksum <"$import_directory/WORK-012.state.json")"
output="$(import_ws import WORK-012 --merged "F0-S9|Bad|1|nothex" 2>&1)"; status_code=$?
expect_equal "import rejects a merge sha that is not hexadecimal" 2 "$status_code"

output="$(import_ws import WORK-013 2>&1)"; status_code=$?
expect_equal "import refuses Approved with no approver and date (no fabricated authority)" 8 "$status_code"
expect_equal "import refusal writes no state" "absent" "$([ -e "$import_directory/WORK-013.state.json" ] && echo present || echo absent)"
output="$(import_ws import WORK-014 2>&1)"; status_code=$?
expect_equal "import refuses a Status line that is not Draft or Approved" 8 "$status_code"
output="$(import_ws import WORK-015 2>&1)"; status_code=$?
expect_equal "import refuses a spec with no Status line" 8 "$status_code"
new_item proposed
run_ws import "$ws_id"
expect_ws "import never touches state that was not imported" 3
for imported in WORK-010 WORK-012; do
  expect_equal "import never produces authorised or delivering: $imported" true "$(import_state '.status | IN("proposed", "approved")' "$imported")"
done

# --- security fix round 1 (M1, L1, L2, L3)
# M1: values are validated as whole strings; a trailing newline cannot slip past a line-based match.
new_item delivering
before="$(state_checksum)"
run_ws decision "$ws_id" --trigger $'3\n' --question q --answer a
expect_ws "M1: decision --trigger '3<newline>' is refused (invalid value)" 2
expect_equal "M1: the refused trigger-3 decision leaves state unchanged" "$before" "$(state_checksum)"
run_ws decision "$ws_id" --trigger $'1\n' --question q --answer a
expect_ws "M1: decision --trigger '1<newline>' is a usage error" 2
run_ws decision "$ws_id" --trigger $'1\n3' --question q --answer a
expect_ws "M1: a multi-line trigger is a usage error" 2
run_ws decision "$ws_id" --trigger 3 --question q --answer a
expect_ws "M1: a plain trigger 3 is still refused as needing the owner command" 4
run_ws block "$ws_id" --trigger $'3\n' --question q
expect_ws "M1: block --trigger '3<newline>' is a usage error" 2
run_ws raise-tier "$ws_id" --inc I1 --tier $'2\n'
expect_ws "M1: a tier with a trailing newline is a usage error" 2
run_ws approve "$ws_id" tier I1 $'0\n' --owner-command approve
expect_ws "M1: approve tier with a trailing newline is a usage error" 2
expect_equal "M1: nothing changed after the refused values" "$before" "$(state_checksum)"

# L1: identifiers and SHAs are whole-string matches; nothing is created outside the specs directory.
lock_listing_before="$(find "$work_directory" -maxdepth 1 -name '.*' | wc -l | tr -d ' ')"
for bad_id in $'WORK-1\n' $'../outside\nWORK-1' $'WORK-1\nx' 'WORK-' 'WORK-1/../x' $'\nWORK-1' 'WORK-12345678901'; do
  run_ws show "$bad_id"
  expect_ws "L1: work id $(printf '%q' "$bad_id") is a usage error" 2
  run_ws create "$bad_id"
  expect_ws "L1: create with work id $(printf '%q' "$bad_id") is a usage error" 2
done
expect_equal "L1: no lock or temp file was created outside the specs directory" "$lock_listing_before" "$(find "$work_directory" -maxdepth 1 -name '.*' | wc -l | tr -d ' ')"
run_ws finding-add "$ws_id" --finding $'F1\n' --source qa --severity low --summary s
expect_ws "L1: --finding with a newline is a usage error" 2
run_ws increment-set "$ws_id" --inc $'I1\n' --status active
expect_ws "L1: --inc with a newline is a usage error" 2
run_ws owner-action-add "$ws_id" --action-id $'A1\n' --description d
expect_ws "L1: --action-id with a newline is a usage error" 2
run_ws finding-add "$ws_id" --finding F9 --source qa --severity low --summary s
run_ws finding-fixed "$ws_id" --finding F9 --sha $'abc1234\n'
expect_ws "L1: a SHA with a newline is a usage error" 2
run_ws finding-fixed "$ws_id" --finding F9 --sha "$(printf 'a%.0s' $(seq 1 65))"
expect_ws "L1: a SHA longer than 64 characters is a usage error" 2
run_ws finding-fixed "$ws_id" --finding F9 --sha abc12
expect_ws "L1: a SHA shorter than 7 characters is a usage error" 2
printf '# Merge fixture\n## Status\nDraft\n' >"$import_directory/WORK-016.md"
output="$(import_ws import WORK-016 --merged $'I1|One|1|abc1234\n' 2>&1)"; status_code=$?
expect_equal "L1: --merged with a newline in the SHA is a usage error" 2 "$status_code"
output="$(import_ws import WORK-016 --merged $'I2|Two|1|abc1234|1\n' 2>&1)"; status_code=$?
expect_equal "L1: --merged with a newline in the tier is a usage error" 2 "$status_code"
output="$(import_ws import WORK-016 --merged $'I3\n|Three|1|abc1234' 2>&1)"; status_code=$?
expect_equal "L1: --merged with a newline in the id is a usage error" 2 "$status_code"
expect_equal "L1: no refused --merged entry was recorded" 0 "$(import_state '.increments | length' WORK-016)"

# L2: an interrupted waiter must not delete the lock it never held.
new_item proposed
mkdir "$ws_directory/.$ws_id.lock"
printf '%s\n' "$$" >"$ws_directory/.$ws_id.lock/pid"
"$workstate" --dir "$ws_directory" check "$ws_id" >/dev/null 2>&1 &
waiter_pid=$!
sleep 1
kill -TERM "$waiter_pid" 2>/dev/null
wait "$waiter_pid" 2>/dev/null
expect_equal "L2: the holder's lock survives an interrupted waiter" present "$([ -d "$ws_directory/.$ws_id.lock" ] && echo present || echo absent)"
expect_equal "L2: and its pid file is intact" "$$" "$(cat "$ws_directory/.$ws_id.lock/pid" 2>/dev/null)"
rm -rf "$ws_directory/.$ws_id.lock"
run_ws check "$ws_id"
expect_ws "L2: a normal run still takes and releases its own lock" 0
expect_equal "L2: the lock is released after a normal run" absent "$([ -d "$ws_directory/.$ws_id.lock" ] && echo present || echo absent)"

# L3: an imported approval is never delivery authority; the owner must approve the spec afresh.
printf '# Imported approved\n## Status\nApproved (by Ashley Oliver, 2026-10-06)\n## Objective\nx\n' >"$import_directory/WORK-017.md"
import_ws import WORK-017 >/dev/null 2>&1
output="$(import_ws deliver WORK-017 --owner-command deliver 2>&1)"; status_code=$?
expect_equal "L3: deliver on an imported approval is refused" 3 "$status_code"
expect_contains "L3: the refusal points to the approve command" "approve WORK-017 spec" "$output"
expect_equal "L3: the item stays approved (imported)" "approved imported" "$(import_state '"\(.status) \(.approval.source)"' WORK-017)"
output="$(import_ws approve WORK-017 spec --owner-command approve 2>&1)"; status_code=$?
expect_equal "L3: approve spec on an imported approval records a fresh owner approval" "0 owner-command" "$status_code $(import_state .approval.source WORK-017)"
output="$(import_ws deliver WORK-017 --owner-command deliver 2>&1)"; status_code=$?
expect_equal "L3: deliver then succeeds" "0 delivering" "$status_code $(import_state .status WORK-017)"
output="$(import_ws approve WORK-017 spec --owner-command approve 2>&1)"; status_code=$?
expect_equal "L3: approve spec on an owner-approved delivering item is still refused" 3 "$status_code"

# --- readiness listing (AC6): read-only, deterministic
new_item delivering
ws finding-add "$ws_id" --finding F1 --source qa --severity high --summary "high one" >/dev/null
ws finding-add "$ws_id" --finding F2 --source security-reviewer --severity critical --security --summary "critical two" >/dev/null
ws finding-add "$ws_id" --finding F3 --source qa --severity low --summary "low open three" >/dev/null
ws finding-add "$ws_id" --finding F4 --source qa --severity medium --summary "medium four" >/dev/null
ws finding-fixed "$ws_id" --finding F1 --sha abc1234 >/dev/null
ws approve "$ws_id" accept F2 --owner-command approve --note "risk accepted" >/dev/null
ws approve "$ws_id" defer F4 --owner-command approve >/dev/null
ws approve "$ws_id" tier I1 0 --owner-command approve >/dev/null
ws decision "$ws_id" --trigger 1 --question "also README?" --answer "no, not in scope" >/dev/null
ws owner-action-add "$ws_id" --action-id A1 --description "gh auth login" --increment I1 >/dev/null
ws owner-action-add "$ws_id" --action-id A2 --description "already done" >/dev/null
ws owner-action-add "$ws_id" --action-id A3 --description "global step" >/dev/null
ws owner-action-done "$ws_id" --action-id A2 >/dev/null
before="$(state_checksum)"
run_ws readiness "$ws_id"
readiness_output="$ws_output"
expect_ws "readiness" 0
expect_equal "readiness: state is byte-identical afterwards" "$before" "$(state_checksum)"
expect_equal "readiness: high and critical findings with dispositions and the fix sha" "F1 high fixed abc1234|F2 critical owner" "$(jq -r '.highFindings | map("\(.id) \(.severity) \(.disposition.state)\(if .disposition.sha then " " + .disposition.sha else "" end)") | join("|")' <<<"$readiness_output")"
expect_equal "readiness: owner-command decisions for accept, defer and tier carry time and spec hash" "3 true $(state_value .approval.specSha256)" "$(jq -r '"\(.ownerDecisions | length) \(.ownerDecisions | all(.at != null)) \(.ownerDecisions | map(.specSha256) | unique | join(","))"' <<<"$readiness_output")"
expect_contains "readiness: the accepted risk is listed" "accept or waive the risk of finding F2" "$readiness_output"
expect_contains "readiness: the deferred finding is listed" "defer finding F4" "$readiness_output"
expect_contains "readiness: the lowered tier is listed" "lower the tier of increment I1 to 0" "$readiness_output"
expect_equal "readiness: conversation decisions" "also README?" "$(jq -r '.conversationDecisions | map(.question) | join("|")' <<<"$readiness_output")"
expect_equal "readiness: open findings" "F3" "$(jq -r '.openFindings | map(.id) | join("|")' <<<"$readiness_output")"
expect_equal "readiness: pending owner actions exclude done ones" "A1|A3" "$(jq -r '.pendingOwnerActions | map(.id) | join("|")' <<<"$readiness_output")"
run_ws readiness "$ws_id" --inc I1
expect_equal "readiness --inc: only that increment's pending actions, with the increment" "A1 I1" "$(jq -r '"\(.pendingOwnerActions | map(.id) | join("|")) \(.increment.id)"' <<<"$ws_output")"
run_ws readiness "$ws_id"
expect_equal "readiness is deterministic" "$readiness_output" "$ws_output"
run_ws readiness "$ws_id" --inc $'I1\n'
expect_ws "readiness: a malformed --inc is a usage error" 2
expect_equal "readiness: still byte-identical after every call" "$before" "$(state_checksum)"
printf '{ broken' >"$work_directory/readiness-corrupt.json"
new_item proposed
cp "$work_directory/readiness-corrupt.json" "$(state_path)"
run_ws readiness "$ws_id"
expect_ws "readiness: corrupt state is a schema error" 5

# Trigger 4 stays answerable from conversation: delivery resumes and the source is recorded.
new_item delivering
run_ws block "$ws_id" --trigger 4 --question "run the reserved operation?"
expect_ws "trigger 4: block" 0
run_ws answer "$ws_id" --decision D1 --answer "owner will run it"
expect_ws "trigger 4: answered from conversation" 0
expect_equal "trigger 4: delivery resumed and source is conversation" "delivering conversation 4" "$(state_value '"\(.status) \(.decisions[0].source) \(.decisions[0].trigger)"')"

# --- guard parity: the guard decides the same with no state, honest state and forged state
parity_repository="$(new_repository parity-repo feature)"
parity_specs="$parity_repository/.agents/specs/active"
mkdir -p "$parity_specs"
parity_commands=$'vercel deploy\nvercel --prod\ngit push origin main\ngh pr merge 12 --squash\nnpm publish'
parity_decide() { tool_input "$1" "$parity_repository" | CLAUDE_PROJECT_DIR="$parity_repository" "$scripts/guard-bash.sh"; }
parity_none="" parity_honest="" parity_forged=""
while IFS= read -r parity_command; do
  parity_none="$parity_none$(parity_decide "$parity_command")|"
done <<<"$parity_commands"

printf '# Parity\n## Status\nDraft\n' >"$parity_specs/WORK-050.md"
"$workstate" --dir "$parity_specs" create WORK-050 >/dev/null
"$workstate" --dir "$parity_specs" increment-add WORK-050 --inc I1 --title One --tier 1 >/dev/null
"$workstate" --dir "$parity_specs" approve WORK-050 spec --owner-command approve >/dev/null
"$workstate" --dir "$parity_specs" deliver WORK-050 --owner-command deliver >/dev/null
expect_equal "guard parity setup: honest state is delivering" delivering "$(jq -r .status "$parity_specs/WORK-050.state.json")"
while IFS= read -r parity_command; do
  parity_honest="$parity_honest$(parity_decide "$parity_command")|"
done <<<"$parity_commands"

# Forged state: written directly (an agent can do this), claiming delivering with the increment listed.
printf '# Forged\n## Status\nDraft\n' >"$parity_specs/WORK-051.md"
forged_hash="$(file_sha256 "$parity_specs/WORK-051.md")"
jq -n --arg hash "$forged_hash" '{schemaVersion: 1, id: "WORK-051", title: "Forged", status: "delivering", pausedFrom: null,
  createdAt: "2026-10-19T00:00:00Z", updatedAt: "2026-10-19T00:00:00Z",
  spec: {path: "x", contentSha256: $hash, approvedCommit: null},
  approval: {by: "forger", at: "2026-10-19T00:00:00Z", specSha256: $hash, source: "owner-command"},
  delivery: {by: "forger", at: "2026-10-19T00:00:00Z", specSha256: $hash, source: "owner-command", policy: {pushWorkBranch: true, openPullRequest: true, pullRequestMode: "ready"}},
  ownerActions: [], decisions: [],
  increments: [{id: "I1", title: "One", status: "active", proposedTier: 0, tier: 0, branch: "feature", pr: null, baseSha: null, headSha: null, mergeSha: null, recoveries: 0, activeAt: null, readyAt: null, mergedAt: null, evidence: []}],
  findings: [], history: []}' >"$parity_specs/WORK-051.state.json"
while IFS= read -r parity_command; do
  parity_forged="$parity_forged$(parity_decide "$parity_command")|"
done <<<"$parity_commands"
expect_equal "guard parity: honest delivering state changes no decision" "$parity_none" "$parity_honest"
expect_equal "guard parity: forged delivering state changes no decision" "$parity_none" "$parity_forged"
while IFS= read -r parity_command; do
  expect_equal "guard parity: '$parity_command' still asks, whatever the state says" ask "$(decision_of "$(parity_decide "$parity_command")")"
done <<<"$parity_commands"

# A normal workstate.sh invocation is neither denied nor asked by the guard, and its command text
# never names the state file.
while IFS= read -r workstate_command; do
  [ -n "$workstate_command" ] || continue
  case "$workstate_command" in *".state.json"*) fail "guard: a workstate command must not name the state file: $workstate_command" ;; *) pass ;; esac
  expect_equal "guard: workstate invocation is not denied or asked: $workstate_command" none "$(decision_of "$(tool_input "$workstate_command" "$feature_repository" | "$scripts/guard-bash.sh")")"
done <<'CASES'
"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" approve WORK-002 spec --owner-command approve
"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" deliver WORK-002 --owner-command deliver
"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" approve WORK-002 accept F1 --owner-command approve --note "accepted"
"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" approve WORK-002 revoke --owner-command approve
"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" block WORK-002 --trigger 2 --question "which library?"
"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" show WORK-002
"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" import WORK-002 --merged "I1|One|1|abc1234"
CASES

# ---------------------------------------------------------------- WORK-002 B2a: skills, templates, banner, wait helper
plugin_directory="$repository_directory/plugins/ai-engineering"
frontmatter_of() { awk -v key="$2" 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside && index($0, key ": ") == 1 { print substr($0, length(key) + 3) }' "$1"; }

# Human-only commands are never model-invocable.
for human_only_skill in approve deliver setup learn review; do
  expect_equal "skill $human_only_skill: disable-model-invocation is true" true "$(frontmatter_of "$plugin_directory/skills/$human_only_skill/SKILL.md" disable-model-invocation)"
done
expect_equal "skill approve: name" approve "$(frontmatter_of "$plugin_directory/skills/approve/SKILL.md" name)"
expect_contains "skill approve: argument hint lists every sub-action" "spec | accept <finding-id> | defer <finding-id> | tier <increment-id> <0|1|2> | revoke" "$(frontmatter_of "$plugin_directory/skills/approve/SKILL.md" argument-hint)"
approve_text="$(cat "$plugin_directory/skills/approve/SKILL.md")"
expect_contains "skill approve: runs the script with the approve owner marker" '--owner-command approve' "$approve_text"
# shellcheck disable=SC2016 # the literal text ${CLAUDE_PLUGIN_ROOT} is what the skill must contain
expect_contains "skill approve: uses the plugin root" '${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh' "$approve_text"
expect_contains "skill approve: says it is not security authority" "not security authority" "$approve_text"
case "$approve_text" in *".state.json"*) fail "skill approve: must not name a state file path" ;; *) pass ;; esac
case "$approve_text" in *[Ss]igned* | *[Ss]ignature*" is a"*) fail "skill approve: must not claim signing" ;; *) pass ;; esac
for approve_exit_code in 0 2 3 4 5 6 7; do
  expect_contains "skill approve: maps exit $approve_exit_code" "- $approve_exit_code:" "$approve_text"
done

deliver_text="$(cat "$plugin_directory/skills/deliver/SKILL.md")"
# shellcheck disable=SC2016 # the literal text $ARGUMENTS is what the skill must contain
expect_contains "skill deliver: first action is the deliver transition" 'workstate.sh" deliver $ARGUMENTS --owner-command deliver' "$deliver_text"
expect_contains "skill deliver: refuses a v0.2 item and points to setup import" "/ai-engineering:setup" "$deliver_text"
case "$deliver_text" in *".state.json"*) fail "skill deliver: must not name a state file path" ;; *) pass ;; esac
# WORK-002 B2b: the rewritten procedure.
expect_contains "skill deliver: sequential in one checkout by default" "Run tasks sequentially in one checkout by default" "$deliver_text"
expect_contains "skill deliver: parallel worktrees are opt-in" "Parallel worktrees are opt-in" "$deliver_text"
expect_contains "skill deliver: one guard confirmation per increment start" "Starting an increment from the updated default branch asks one guard confirmation" "$deliver_text"
expect_contains "skill deliver: each worktree merge also asks" "each worktree merge also asks" "$deliver_text"
expect_contains "skill deliver: records the base once at the start" "--status active --branch <work-branch> --base-sha <commit>" "$deliver_text"
expect_contains "skill deliver: the start command names the full base commit" "\`git switch -c <work-branch> <commit>\` naming that full commit" "$deliver_text"
case "$deliver_text" in *"git switch -c <work-branch> origin/<default>"*) fail "skill deliver: the start command must not name origin/<default>" ;; *) pass ;; esac
expect_contains "skill deliver: never moves the default-branch ref during an increment" "Do not fetch, pull or otherwise move \`origin/<default>\` again until the increment is merged" "$deliver_text"
expect_contains "skill deliver: confirmation never pre-authorises another prompt" "never replaces, suppresses or pre-authorises any other guard prompt" "$deliver_text"
expect_contains "skill deliver: owner-command records are not security authority" "workflow records, not security authority" "$deliver_text"
expect_contains "skill deliver: coordinator owns Git, never merges" "never merge" "$deliver_text"
expect_contains "skill deliver: specialists edit and test only" "Specialists edit files and run tests only" "$deliver_text"
expect_contains "skill deliver: trigger 1" "1. intent or scope change" "$deliver_text"
expect_contains "skill deliver: trigger 2" "2. an owner-level trade-off" "$deliver_text"
expect_contains "skill deliver: trigger 3" "3. accepting, waiving, deferring or downgrading risk, or disputing a security finding" "$deliver_text"
expect_contains "skill deliver: trigger 4" "4. a reserved operation" "$deliver_text"
expect_contains "skill deliver: trigger 5" "5. an ambiguity whose readings build different things" "$deliver_text"
expect_contains "skill deliver: blocks with a trigger class" "workstate.sh block --trigger" "$deliver_text"
expect_contains "skill deliver: weakening a control is trigger 3" "Weakening a test, gate or control to clear a finding is trigger 3" "$deliver_text"
expect_contains "skill deliver: records fixes" "workstate.sh finding-fixed" "$deliver_text"
expect_contains "skill deliver: security findings need the reviewer's confirmation" "--confirmed-by" "$deliver_text"
expect_contains "skill deliver: conversation decisions are recorded" "source \`conversation\`" "$deliver_text"
expect_contains "skill deliver: risk, tier and scope need approve" "Accepting risk, lowering a tier and adding scope need \`/ai-engineering:approve\`" "$deliver_text"
expect_contains "skill deliver: runs the review skill procedure" "Run the \`review\` skill procedure" "$deliver_text"
expect_contains "skill deliver: readiness lists HIGH-or-above fixes and risk decisions" "every fix of HIGH severity or above, and every owner-command decision" "$deliver_text"
expect_contains "skill deliver: waits for the merge in the background" 'wait-github.sh" merge' "$deliver_text"
expect_contains "skill deliver: an expired wait is a planned owner action" "waiting for owner merge" "$deliver_text"
expect_contains "skill deliver: not authenticated is a planned owner action" "NOT AUTHENTICATED" "$deliver_text"
expect_contains "skill deliver: finishes with done" "workstate.sh done" "$deliver_text"
expect_contains "skill deliver: records one recovery" "workstate.sh increment-recovery" "$deliver_text"
# WORK-002 E2E findings: E2 (scope request) and E3 (owner stop versus stall).
expect_contains "skill deliver: a scope-only request is a non-blocking proposal" "workstate.sh propose --question" "$deliver_text"
expect_contains "skill deliver: a proposal is not implemented and delivery continues" "do not implement it, tell the owner in one line, and continue the approved scope" "$deliver_text"
expect_contains "skill deliver: block on trigger 1 only when the approved work cannot continue" "Block on trigger 1 only when the approved work cannot continue correctly without the answer" "$deliver_text"
expect_contains "skill deliver: recovery is automatic and asks nothing" "re-dispatched once automatically with a fresh brief, without asking" "$deliver_text"
expect_contains "skill deliver: an owner stop is a pause, not a stall" "A specialist the owner stops is an owner instruction, not a stall: do not re-dispatch it" "$deliver_text"
expect_contains "skill deliver: an owner stop is recorded as an owner pause" "workstate.sh pause --actor owner" "$deliver_text"
expect_contains "skill deliver: readiness lists open decisions and proposals" "every open decision or scope proposal" "$deliver_text"
# Security re-check L1, L2 and E2 re-test defects.
expect_contains "skill deliver: an accepted proposal is never built under the current approval" "scope the owner accepts is never implemented under the current approval" "$deliver_text"
expect_contains "skill deliver: an unclear stop is treated as an owner stop" "If it is unclear whether the owner stopped it, treat it as an owner stop" "$deliver_text"
expect_contains "skill deliver: only the blocking decision resumes" "Only the decision that caused the block resumes it" "$deliver_text"
expect_contains "skill deliver: deliver resumes after approve --decision" "then \`/ai-engineering:deliver <WORK-ID>\`" "$deliver_text"
expect_contains "skill deliver: fields can be recorded without a status change" "omit \`--status\`" "$deliver_text"
expect_contains "skill approve: points to deliver to resume after a decision" "suggest \`/ai-engineering:deliver <WORK-ID>\` to resume it" "$approve_text"
expect_contains "skill deliver: lean handoff excludes the log and legacy sections" 'Never pass the log, the conversation, or a legacy v0.2 "Implementation state" or "Review state" section' "$deliver_text"
expect_contains "skill deliver: keeps the high-impact boundary" "the guard hook will ask the human" "$deliver_text"
expect_contains "skill deliver: runs the fast gate through run-gate.sh" 'run-gate.sh" fast' "$deliver_text"
case "$deliver_text" in *"## Prove"*) fail "skill deliver: the Prove section is removed" ;; *) pass ;; esac
case "$deliver_text" in *[Pp]laybook*) fail "skill deliver: playbook selection is removed" ;; *) pass ;; esac
case "$deliver_text" in *"goes to the user"*) fail "skill deliver: 'goes to the user' is removed" ;; *) pass ;; esac
case "$deliver_text" in *"Record the task list under"*) fail "skill deliver: must not write the legacy Implementation state" ;; *) pass ;; esac
case "$deliver_text" in *[Ss]igned* | *"autonomous deploy"*" is "*) fail "skill deliver: must not claim signing or autonomous deployment" ;; *) pass ;; esac
# AC9: the increment start is one guard confirmation only with this exact sequence.
expect_contains "skill deliver: increment start fetches the default branch" 'git fetch origin <default>' "$deliver_text"
expect_contains "skill deliver: increment start is one switch from the remote default" 'git switch -c <work-branch> <commit>' "$deliver_text"
# A review that wrote into the spec would change its hash and stop delivery.
review_text="$(cat "$plugin_directory/skills/review/SKILL.md")"
expect_contains "skill review: items with state are recorded as evidence, not in the spec" "never edit the spec" "$review_text"
expect_contains "skill review: items with state use workstate.sh evidence" "workstate.sh evidence" "$review_text"
# WORK-003 C2: one deterministic readiness procedure.
expect_contains "skill review: runs the readiness script" 'scripts/readiness.sh" <WORK-ID> --inc <increment-id>' "$review_text"
expect_contains "skill review: never replaces readiness lines with judgement" "Never replace any of its lines with your own judgement" "$review_text"
expect_contains "skill review: base is the merge-base, never chosen" "never a chosen ref" "$review_text"
expect_contains "skill review: evidence names reviewer and commit" "--reviewer qa|security --result pass|fail --sha <commit>" "$review_text"
expect_contains "skill review: tier-2 residual-risk list with its result and commit" "--kind residual-risks --result pass --sha <commit>" "$review_text"
expect_contains "skill review: the base is the recorded increment base" "the increment's recorded base commit, which must still equal \`origin/<default>\`" "$review_text"
expect_contains "skill review: security review at tier 2" "\`ai-engineering:security-reviewer\` at tier 2." "$review_text"
case "$review_text" in *"security category"*) fail "skill review: the unreachable tier-1 security-category rule is gone" ;; *) pass ;; esac
expect_contains "skill review: a configured reviewer's failure blocks at every tier" "a configured reviewer's \`BLOCKING FINDINGS\` or \`ERROR\` is READY: NO at every tier" "$review_text"
expect_contains "skill review: the gate runs in a fresh clone, never re-run in the checkout" "never re-run it in the checkout to get a pass" "$review_text"
expect_contains "skill review: readiness runs in the background and is waited for" "Run the script as a background Bash command, wait for its completion notification" "$review_text"
expect_contains "skill review: no verdict before completion" "Never report a verdict before the run has completed" "$review_text"
expect_contains "skill review: READY YES does not prove approval or the base" "the guard log records that the start command was asked, not that it was approved or ran" "$review_text"
expect_contains "skill review: NOT CERTIFIABLE differs from tier 2" "it is not the same as a valid tier-2 classification" "$review_text"
expect_contains "skill review: external review required at tiers 1 and 2" "External review is required at tiers 1 and 2" "$review_text"
expect_contains "skill review: nothing substitutes for external review" "Owner merge approval, Opus or QA reviews never substitute for it" "$review_text"
case "$review_text" in *"run-gate.sh\" full . <base>"*) fail "skill review: the gate must not be run against a chosen base" ;; *) pass ;; esac
expect_contains "skill deliver: records worktree branches" "workstate.sh increment-worktree --inc <id> --branch <worktree-branch>" "$deliver_text"
# shellcheck disable=SC2016 # the literal backticks are what the skill must contain
expect_contains "skill deliver: exact worktree merge command" 'merge each with exactly `git merge --no-edit <worktree-branch>`' "$deliver_text"
# shellcheck disable=SC2016 # the literal backticks are what the skill must contain
expect_contains "skill deliver: exact resume command" 'use exactly `git switch <work-branch>`' "$deliver_text"
expect_contains "skill deliver: other forms raise the tier" "any other form, and every other guard prompt, raises the increment to tier 2" "$deliver_text"
expect_contains "skill deliver: review evidence names reviewer and commit" "--reviewer qa|security --sha <commit>" "$deliver_text"
expect_contains "skill deliver: reports NOT CERTIFIABLE as it is" "Report NOT CERTIFIABLE and READY: NO as they are" "$deliver_text"

work_spec_template="$plugin_directory/skills/plan/templates/work-spec.md"
for template_section in "## Increments" "## Delivery policy" "## Owner actions"; do
  expect_equal "spec template has section $template_section" 1 "$(grep -cxF "$template_section" "$work_spec_template")"
done
for dropped_section in "## Implementation state" "## Review state"; do
  expect_equal "spec template drops $dropped_section" 0 "$(grep -cxF "$dropped_section" "$work_spec_template")"
done
# The template's own Delivery policy section is accepted by the transition script as written.
template_directory="$work_directory/template-specs"
mkdir -p "$template_directory"
cp "$work_spec_template" "$template_directory/WORK-070.md"
template_ws() { "$workstate" --dir "$template_directory" "$@"; }
template_ws create WORK-070 >/dev/null 2>&1
template_ws increment-add WORK-070 --inc I1 --title One --tier 1 >/dev/null 2>&1
template_ws approve WORK-070 spec --owner-command approve >/dev/null 2>&1
template_ws deliver WORK-070 --owner-command deliver >/dev/null 2>&1
expect_equal "spec template: default delivery policy parses" "delivering true true" "$(jq -r '"\(.status) \(.delivery.policy.pushWorkBranch) \(.delivery.policy.openPullRequest)"' "$template_directory/WORK-070.state.json" 2>/dev/null)"
plan_text="$(cat "$plugin_directory/skills/plan/SKILL.md")"
expect_contains "skill plan: records state through create" 'workstate.sh" create' "$plan_text"
expect_contains "skill plan: ends by pointing at approve" '/ai-engineering:approve <WORK-ID>' "$plan_text"
expect_contains "skill plan: conversational approval changes nothing" "never changes status" "$plan_text"
case "$plan_text" in *"Set the spec status to \`Approved\`"*) fail "skill plan: must not set Approved itself" ;; *) pass ;; esac

setup_settings="$plugin_directory/skills/setup/templates/settings.json"
expect_equal "setup template: worktree.baseRef is head" head "$(jq -r '.worktree.baseRef' "$setup_settings")"
expect_equal "setup template: still pins the marketplace ref" "v{{PLUGIN_VERSION}}" "$(jq -r '.extraKnownMarketplaces["ai-engineering-system"].source.ref' "$setup_settings")"
setup_text="$(cat "$plugin_directory/skills/setup/SKILL.md")"
expect_contains "skill setup: documents the import mode" 'workstate.sh" import' "$setup_text"
expect_contains "skill setup: documents the --merged option" "--merged" "$setup_text"
expect_contains "skill setup: documents the claude --worktree effect and opt-out" "claude --worktree" "$setup_text"
case "$setup_text" in *"Ask whether the project wants parallel"*) fail "skill setup: the worktree question is removed" ;; *) pass ;; esac

# Session banner: plugin version and root.
banner_output="$(CLAUDE_PLUGIN_ROOT="$plugin_directory" "$scripts/inject-standards.sh")"
banner_version="$(jq -r '.version' "$plugin_directory/.claude-plugin/plugin.json")"
expect_contains "banner: shows the plugin version" "ai-engineering $banner_version," "$banner_output"
expect_contains "banner: shows the plugin root" "plugin root $plugin_directory" "$banner_output"

# Specialists: edit and test only, tagged open questions, no log or legacy sections.
for specialist in frontend backend platform; do
  specialist_text="$(cat "$plugin_directory/agents/$specialist.md")"
  expect_contains "agent $specialist: makes no Git writes" "make no Git writes" "$specialist_text"
  expect_contains "agent $specialist: tags open questions with a trigger" "proposed trigger" "$specialist_text"
  expect_contains "agent $specialist: ignores log and legacy sections" 'ignore its log and any legacy "Implementation state" and "Review state" sections' "$specialist_text"
done

# Security reviewer execution limits (WORK-002 E1 and WORK-003 C1 breaches): procedural, not a sandbox.
reviewer_file="$plugin_directory/agents/security-reviewer.md"
reviewer_text="$(cat "$reviewer_file")"
expect_equal "agent security-reviewer: has one Execution limits section" 1 "$(grep -cxF "## Execution limits" "$reviewer_file")"
expect_contains "agent security-reviewer: limits are procedural, not a sandbox" "These are procedural instructions, not a sandbox" "$reviewer_text"
expect_contains "agent security-reviewer: guard behaviour unchanged" "the guard still asks or denies exactly as before" "$reviewer_text"
expect_contains "agent security-reviewer: only owner-authorised exceptions" "unless the brief states that the owner authorised a specific exception for this review" "$reviewer_text"
expect_contains "agent security-reviewer: one simple command per call" "One simple command per Bash call" "$reviewer_text"
# shellcheck disable=SC2016 # the literal backticks are what the agent file must contain
expect_contains "agent security-reviewer: no chaining" 'Do not chain commands with `&&`, `||`, `;`, `&` or pipes' "$reviewer_text"
expect_contains "agent security-reviewer: bounded inputs" "Bounded inputs only: no input larger than 10 KB" "$reviewer_text"
expect_contains "agent security-reviewer: no stress or oversized runs" "no stress, fuzz, load or oversized-input runs" "$reviewer_text"
expect_contains "agent security-reviewer: isolated scratch probes" "Probe only in a fresh, isolated scratch directory" "$reviewer_text"
expect_contains "agent security-reviewer: never writes to the repository" "Never write to the repository" "$reviewer_text"
# shellcheck disable=SC2016 # the literal backticks are what the agent file must contain
expect_contains "agent security-reviewer: no deletes" 'No deletes: no `rm`, `find -delete` or `git clean`' "$reviewer_text"
expect_contains "agent security-reviewer: no vulnerable base versions without authorisation" "Never run the base, original or a known-vulnerable version of the code" "$reviewer_text"
expect_contains "agent security-reviewer: authorisation must be explicit" "without explicit authorisation in the brief" "$reviewer_text"
expect_contains "agent security-reviewer: no retry of declined commands" "do not retry it, split it or rephrase it to reach the same effect" "$reviewer_text"
expect_contains "agent security-reviewer: lists executed commands" "List every command you executed in the report" "$reviewer_text"
expect_equal "agent security-reviewer: still has no Edit or Write tool" "tools: Read, Grep, Glob, Bash" "$(grep -m1 '^tools: ' "$reviewer_file")"
expect_contains "skill review: briefs the reviewer with the execution limits" "follow the Execution limits in its agent definition" "$review_text"
expect_contains "skill review: exceptions only when the owner authorised them" "name any exception only when the owner authorised it for this review" "$review_text"
expect_contains "skill review: limits are procedural, not a sandbox" "The limits are procedural, not a sandbox." "$review_text"

# ---- wait-github.sh with a fake gh on PATH
wait_helper="$scripts/wait-github.sh"
fake_gh_directory="$work_directory/fake-gh"
mkdir -p "$fake_gh_directory/bin" "$fake_gh_directory/bodies"
cat >"$fake_gh_directory/bin/gh" <<'FAKE'
#!/bin/bash
# Fake gh: FAKE_GH_AUTH=0 means logged out. Other calls print the next body file and exit FAKE_GH_EXIT.
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
if [ "$1" = auth ]; then exit "${FAKE_GH_AUTH:-0}"; fi
printf 'token ghp_SECRETTOKENVALUE0123456789 rejected\n' >&2
count_file="$FAKE_GH_BODIES/count"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$count" >"$count_file"
body="$FAKE_GH_BODIES/$count.json"
[ -f "$body" ] || body="$(ls "$FAKE_GH_BODIES"/*.json | sort -V | tail -n 1)"
cat "$body"
exit "${FAKE_GH_EXIT:-0}"
FAKE
chmod +x "$fake_gh_directory/bin/gh"

run_wait() { # bodies-and-env are set by the caller; args are passed to the helper
  wait_output="$(PATH="$fake_gh_directory/bin:$PATH" FAKE_GH_LOG="$fake_gh_directory/log" FAKE_GH_BODIES="$fake_gh_directory/bodies" "$wait_helper" "$@" 2>&1)"
  wait_status=$?
}
set_bodies() { rm -f "$fake_gh_directory/bodies"/*; : >"$fake_gh_directory/log"; local number=0 body; for body in "$@"; do number=$((number + 1)); printf '%s' "$body" >"$fake_gh_directory/bodies/$number.json"; done; }
fast_wait=(--timeout 0 --interval 1)
retry_wait=(--timeout 10 --interval 1 --max-interval 1)
rate_limit_payload='{"message":"API rate limit exceeded for user ID 1.","documentation_url":"https://docs.github.com/rest"}'
pass_checks='[{"name":"build","bucket":"pass"},{"name":"lint","bucket":"skipping"}]'
pending_checks='[{"name":"build","bucket":"pass"},{"name":"test","bucket":"pending"}]'
fail_checks='[{"name":"build","bucket":"pass"},{"name":"test","bucket":"fail"}]'

set_bodies "$pass_checks"; run_wait "${fast_wait[@]}" checks 12
expect_equal "wait checks pr: success exit" 0 "$wait_status"; expect_contains "wait checks pr: success verdict" "CHECKS PASSED: 12" "$wait_output"
set_bodies "$fail_checks"; run_wait "${fast_wait[@]}" checks 12
expect_equal "wait checks pr: failure exit" 1 "$wait_status"; expect_contains "wait checks pr: failure verdict names the check" "CHECKS FAILED: 12 (test)" "$wait_output"
set_bodies "$pending_checks" "$pass_checks"; run_wait "${retry_wait[@]}" checks 12
expect_equal "wait checks pr: pending then success" 0 "$wait_status"
set_bodies "$pending_checks"; run_wait "${fast_wait[@]}" checks 12
expect_equal "wait checks pr: timeout exit" 4 "$wait_status"; expect_contains "wait checks pr: timeout verdict" "TIMEOUT:" "$wait_output"
set_bodies "[]"; run_wait "${fast_wait[@]}" checks 12
expect_equal "wait checks pr: no checks yet is pending, not success" 4 "$wait_status"
set_bodies '{"total_count":2,"check_runs":[{"name":"build","status":"completed","conclusion":"success"},{"name":"lint","status":"completed","conclusion":"neutral"}]}'; run_wait "${fast_wait[@]}" checks abc1234
expect_equal "wait checks sha: success exit" 0 "$wait_status"
set_bodies '{"total_count":2,"check_runs":[{"name":"build","status":"completed","conclusion":"success"},{"name":"lint","status":"completed","conclusion":"failure"}]}'; run_wait "${fast_wait[@]}" checks abc1234
expect_equal "wait checks sha: failure exit" 1 "$wait_status"
set_bodies '{"total_count":1,"check_runs":[{"name":"build","status":"in_progress","conclusion":null}]}'; run_wait "${fast_wait[@]}" checks abc1234
expect_equal "wait checks sha: in progress times out" 4 "$wait_status"
# L5: a truncated first page (total_count above the runs returned) is never a pass.
truncated_runs="$(jq -nc '{total_count: 150, check_runs: [range(100) | {name: "run\(.)", status: "completed", conclusion: "success"}]}')"
set_bodies "$truncated_runs"; run_wait "${fast_wait[@]}" checks abc1234
expect_equal "wait checks sha: total_count 150 with 100 runs is not a pass" true "$([ "$wait_status" != 0 ] && echo true || echo false)"
set_bodies "$truncated_runs"; run_wait "${retry_wait[@]}" checks abc1234
expect_equal "wait checks sha: a truncated page ends in the error verdict" 5 "$wait_status"
run_wait --timeout 5 --interval 0 checks 12
expect_equal "wait: --interval 0 is a usage error" 2 "$wait_status"
run_wait --timeout 5 --max-interval 0 checks 12
expect_equal "wait: --max-interval 0 is a usage error" 2 "$wait_status"
run_wait --timeout 5 checks $'abc1234\n'
expect_equal "wait: a sha with a trailing newline is a usage error" 2 "$wait_status"

# Error payloads and malformed data are never data.
set_bodies "$rate_limit_payload"; run_wait "${retry_wait[@]}" checks 12
expect_equal "wait checks pr: rate-limit payload is an error" 5 "$wait_status"; expect_contains "wait: rate-limit verdict" "ERROR:" "$wait_output"
set_bodies "$rate_limit_payload"; run_wait "${retry_wait[@]}" checks abc1234
expect_equal "wait checks sha: rate-limit payload is an error" 5 "$wait_status"
set_bodies "$rate_limit_payload"; FAKE_GH_EXIT=1 run_wait "${retry_wait[@]}" merge 12
expect_equal "wait merge: rate-limit payload is an error" 5 "$wait_status"
set_bodies 'not json {'; run_wait "${retry_wait[@]}" checks 12
expect_equal "wait checks: malformed JSON is an error" 5 "$wait_status"
set_bodies ''; run_wait "${retry_wait[@]}" merge 12
expect_equal "wait merge: empty response is an error" 5 "$wait_status"
set_bodies '[{"name":"build","bucket":"mystery"}]'; run_wait "${retry_wait[@]}" checks 12
expect_equal "wait checks: an unknown bucket is an error, not a pass" 5 "$wait_status"
set_bodies '{"state":"SOMETHING"}'; run_wait "${retry_wait[@]}" merge 12
expect_equal "wait merge: an unknown state is an error, not a result" 5 "$wait_status"
set_bodies "$rate_limit_payload" "$pass_checks"; run_wait "${retry_wait[@]}" checks 12
expect_equal "wait: one transient error is retried" 0 "$wait_status"
case "$wait_output" in *ghp_SECRETTOKEN*) fail "wait: a token must never reach the output" ;; *) pass ;; esac
set_bodies 'not json {'; run_wait "${retry_wait[@]}" checks 12
case "$wait_output" in *ghp_SECRETTOKEN* | *"not json"*) fail "wait: raw gh output must never reach the output" ;; *) pass ;; esac
expect_equal "wait: exactly one verdict line" 1 "$(printf '%s\n' "$wait_output" | wc -l | tr -d ' ')"

# Merge mode.
set_bodies '{"state":"MERGED","mergeCommit":{"oid":"abc1234"}}'; run_wait "${fast_wait[@]}" merge 12
expect_equal "wait merge: merged exit" 0 "$wait_status"; expect_contains "wait merge: merged verdict" "MERGED: PR 12" "$wait_output"
set_bodies '{"state":"CLOSED","mergeCommit":null}'; run_wait "${fast_wait[@]}" merge 12
expect_equal "wait merge: closed without merge exit" 1 "$wait_status"; expect_contains "wait merge: closed verdict" "PR CLOSED NOT MERGED" "$wait_output"
set_bodies '{"state":"OPEN","mergeCommit":null}'; run_wait "${fast_wait[@]}" merge 12
expect_equal "wait merge: open until timeout" 4 "$wait_status"
set_bodies '{"state":"OPEN"}' '{"state":"MERGED"}'; run_wait "${retry_wait[@]}" merge 12
expect_equal "wait merge: open then merged" 0 "$wait_status"

# Unauthenticated: a planned owner action, and no API call is ever made.
set_bodies "$pass_checks"; FAKE_GH_AUTH=1 run_wait "${fast_wait[@]}" checks 12
expect_equal "wait: unauthenticated exit" 3 "$wait_status"; expect_contains "wait: unauthenticated verdict" "NOT AUTHENTICATED" "$wait_output"
expect_equal "wait: unauthenticated makes no call beyond auth status" 0 "$(grep -vc '^auth status' "$fake_gh_directory/log")"
wait_output="$(PATH="/usr/bin:/bin" FAKE_GH_LOG="$fake_gh_directory/log" "$wait_helper" "${fast_wait[@]}" merge 12 2>&1)"; wait_status=$?
case "$(command -v gh 2>/dev/null)" in /usr/bin/gh | /bin/gh) pass ;; *) expect_equal "wait: missing gh is NOT AUTHENTICATED" 3 "$wait_status" ;; esac

# Usage errors, including injection-shaped targets.
# shellcheck disable=SC2016 # the literal text $(id) is an injection-shaped argument under test
for bad_arguments in "checks" "bogus 12" "merge abc1234" "checks 12;id" 'checks $(id)' "merge 12 extra" "--timeout x checks 12" "--nope checks 12" "checks abc123abc123abc123abc123abc123abc123abc12"; do
  # shellcheck disable=SC2086 # intentional word splitting of the table entry
  run_wait "${fast_wait[@]}" $bad_arguments
  expect_equal "wait: usage error for '$bad_arguments'" 2 "$wait_status"
done

# ---------------------------------------------------------------- WORK-003 C2: readiness
# Fixtures: a Claude Code config directory (plugin registry and known marketplaces), a
# marketplace clone whose tag holds this plugin, the installed copy readiness runs from, and a
# project with a local bare remote. Every scenario runs the installed readiness.sh.
readiness_root="$work_directory/readiness"
mkdir -p "$readiness_root"
readiness_git() { git -C "$1" -c user.name=test -c user.email=test@example.com "${@:2}" </dev/null; }
text_sha256() { if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; else printf '%s' "$1" | sha256sum | cut -d' ' -f1; fi; }
readiness_version="$(jq -r .version "$plugin_directory/.claude-plugin/plugin.json")"
expect_equal "readiness: guard-log cap matches guard-bash.sh" \
  "$(sed -n 's/^log_max_bytes=\([0-9]*\).*/\1/p' "$scripts/guard-bash.sh")" \
  "$(sed -n 's/^guard_log_cap=\([0-9]*\).*/\1/p' "$scripts/readiness.sh")"

marketplace_clone="$readiness_root/marketplace"
mkdir -p "$marketplace_clone/.claude-plugin" "$marketplace_clone/plugins"
cp -R "$plugin_directory" "$marketplace_clone/plugins/ai-engineering"
cp "$repository_directory/.claude-plugin/marketplace.json" "$marketplace_clone/.claude-plugin/marketplace.json"
readiness_git "$marketplace_clone" init -q -b main
readiness_git "$marketplace_clone" add -A
readiness_git "$marketplace_clone" commit -q -m release
readiness_git "$marketplace_clone" tag "v$readiness_version"
marketplace_commit="$(readiness_git "$marketplace_clone" rev-parse HEAD)"
install_directory="$readiness_root/cache/ai-engineering/$readiness_version"
mkdir -p "$install_directory"
cp -R "$marketplace_clone/plugins/ai-engineering/." "$install_directory/"
mkdir -p "$install_directory/.in_use"
printf '1\n' >"$install_directory/.in_use/4242"
installed_readiness="$install_directory/scripts/readiness.sh"

config_directory="$readiness_root/config"
mkdir -p "$config_directory/plugins"
write_registry() { # entries JSON array
  jq -n --argjson entries "$1" '{version: 2, plugins: {"ai-engineering@ai-engineering-system": $entries}}' >"$config_directory/plugins/installed_plugins.json"
}
user_entry() { # [install path] [version] [commit]
  jq -n -c --arg path "${1:-$install_directory}" --arg version "${2:-$readiness_version}" --arg commit "${3:-$marketplace_commit}" \
    '{scope: "user", installPath: $path, version: $version, gitCommitSha: $commit, installedAt: "2026-10-20T00:00:00Z"}'
}
write_known() { # [ref] [clone location]
  jq -n --arg ref "${1:-v$readiness_version}" --arg location "${2:-$marketplace_clone}" \
    '{"ai-engineering-system": {source: {source: "github", repo: "asholiver/ai-engineering-system", ref: $ref}, installLocation: $location, autoUpdate: false}}' \
    >"$config_directory/plugins/known_marketplaces.json"
}
reset_trust() { write_registry "[$(user_entry)]"; write_known; }
reset_trust

ws_ready() { (cd "$readiness_project" && "$install_directory/scripts/workstate.sh" "$@"); }
guard_event() { # decision command session [time]
  jq -n -c --arg time "${4:-2000-01-01T00:00:01Z}" --arg decision "$1" --arg sha "$(text_sha256 "$2")" --arg session "$3" \
    '{time: $time, sessionId: $session, agentType: null, decision: $decision, classes: ["fixture-class"], parseMode: "parsed", commandSha256: $sha}'
}
guard_log_file() { printf '%s/.git/ai-engineering/guard-log.jsonl' "$readiness_project"; }
start_command="" # set by build_readiness_project: the start command names the base commit
reset_guard_log() {
  rm -rf "${readiness_project:?}/.git/ai-engineering"
  mkdir -p "$readiness_project/.git/ai-engineering"
  guard_event ask "$start_command" coordinator 2000-01-01T00:00:00Z >"$(guard_log_file)"
}
real_guard() { # command [session]: one Bash tool call through the real installed guard (never executed)
  jq -n --arg command "$1" --arg cwd "$readiness_project" --arg session "${2:-real-session}" \
    '{tool_name: "Bash", tool_input: {command: $command}, cwd: $cwd, session_id: $session}' | "$install_directory/scripts/guard-bash.sh" >/dev/null 2>&1
}

# Builds a project on main (pin, gates, spec, state), pushes it, and starts increment I1 on
# its work branch (base recorded) with one tier-0 README change and QA evidence for that commit.
# readiness_pin_ref overrides the pinned ref ("none": no .claude/settings.json); with
# readiness_real_guard=yes the start confirmation goes through the real guard instead of a
# fixture log line.
readiness_pin_ref=""
readiness_real_guard=no
readiness_plant_base=no
build_readiness_project() { # name external-review-json state-tier [full-gate-command]
  readiness_project="$readiness_root/$1"
  git init -q --bare "$readiness_root/$1.git"
  git init -q -b main "$readiness_project"
  mkdir -p "$readiness_project/.claude" "$readiness_project/.agents/specs/active"
  if [ "$readiness_pin_ref" != none ]; then
    jq -n --arg ref "${readiness_pin_ref:-v$readiness_version}" '{extraKnownMarketplaces: {"ai-engineering-system": {source: {source: "github", repo: "asholiver/ai-engineering-system", ref: $ref}, autoUpdate: false}}, enabledPlugins: {"ai-engineering@ai-engineering-system": true}}' \
      >"$readiness_project/.claude/settings.json"
  fi
  jq -n --argjson external "$2" --arg full "${4-true}" '{fast: "true", full: $full, externalReview: $external}' >"$readiness_project/.agents/gates.json"
  printf '# WORK-001 readiness fixture\n## Status\nDraft\n## Objective\nReadiness fixture.\n' >"$readiness_project/.agents/specs/active/WORK-001.md"
  printf '# Project\n' >"$readiness_project/README.md"
  printf '{"name": "fixture"}\n' >"$readiness_project/package.json"
  ws_ready create WORK-001 >/dev/null
  ws_ready increment-add WORK-001 --inc I1 --title One --tier "$3" >/dev/null
  readiness_git "$readiness_project" add -A
  readiness_git "$readiness_project" commit -q -m seed
  readiness_git "$readiness_project" remote add origin "$readiness_root/$1.git"
  readiness_git "$readiness_project" push -q origin main
  readiness_git "$readiness_project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  ws_ready approve WORK-001 spec --owner-command approve >/dev/null
  ws_ready deliver WORK-001 --owner-command deliver >/dev/null
  if [ "$readiness_plant_base" = yes ]; then
    # A commit that is not on the remote's main, planted in the local default-branch ref.
    readiness_git "$readiness_project" update-ref refs/remotes/origin/main \
      "$(readiness_git "$readiness_project" commit-tree -p HEAD -m planted "HEAD^{tree}")"
  fi
  # The owner-approved start command names the full base commit.
  readiness_base="$(readiness_git "$readiness_project" rev-parse refs/remotes/origin/main)"
  start_command="git switch -c work/WORK-001-I1 $readiness_base"
  readiness_git "$readiness_project" switch -q -c work/WORK-001-I1 "$readiness_base"
  if [ "$readiness_real_guard" = yes ]; then
    rm -rf "${readiness_project:?}/.git/ai-engineering"
    real_guard "$start_command" real-session
  fi
  ws_ready increment-set WORK-001 --inc I1 --status active --branch work/WORK-001-I1 --base-sha "$readiness_base" >/dev/null
  commit_change README.md
  ws_ready evidence WORK-001 --inc I1 --kind review --reviewer qa --result pass --sha "$(readiness_git "$readiness_project" rev-parse HEAD)" >/dev/null
  [ "$readiness_real_guard" = yes ] || reset_guard_log
}
readiness_state_file() { printf '%s/.agents/specs/active/WORK-001.state.json' "$readiness_project"; }
edit_readiness_state() { # jq filter applied to the live state file
  jq "$1" "$(readiness_state_file)" >"$readiness_root/edited-state.json" && cp "$readiness_root/edited-state.json" "$(readiness_state_file)"
}
commit_change() { # path...: appends a line to each path and commits only those paths
  local changed_path
  for changed_path in "$@"; do printf 'more\n' >>"$readiness_project/$changed_path"; done
  readiness_git "$readiness_project" add -- "$@"
  readiness_git "$readiness_project" commit -q -m change
}
record_review() { # reviewer|residual-risks: passing evidence for HEAD
  if [ "$1" = residual-risks ]; then
    ws_ready evidence WORK-001 --inc I1 --kind residual-risks --result pass --sha "$(readiness_git "$readiness_project" rev-parse HEAD)" >/dev/null
  else
    ws_ready evidence WORK-001 --inc I1 --kind review --reviewer "$1" --result pass --sha "$(readiness_git "$readiness_project" rev-parse HEAD)" >/dev/null
  fi
}
run_readiness() { # [readiness script]
  readiness_output="$(CLAUDE_CONFIG_DIR="$config_directory" "${1:-$installed_readiness}" WORK-001 --inc I1 "$readiness_project" 2>&1)"
  readiness_status=$?
}
readiness_line() { printf '%s\n' "$readiness_output" | grep "^$1" | head -n 1; }
expect_not_certifiable() { # label reason-fragment
  expect_equal "$1: exit 3 (not certifiable)" 3 "$readiness_status"
  expect_equal "$1: effective tier 2, marked not certifiable" "EFFECTIVE TIER: 2 (NOT CERTIFIABLE)" "$(readiness_line "EFFECTIVE TIER:")"
  expect_contains "$1: names the reason" "$2" "$(readiness_line "CERTIFIABLE:")"
  expect_contains "$1: READY NO" "READY: NO" "$(readiness_line "READY:")"
}
expect_ready_yes() { # label
  expect_equal "$1: exit 0" 0 "$readiness_status"
  expect_equal "$1: READY YES" "READY: YES" "$(readiness_line "READY:")"
  expect_equal "$1: certifiable" "CERTIFIABLE: YES" "$(readiness_line "CERTIFIABLE:")"
}
# A valid tier-2 classification from one raising guard event: certifiable, exit 1, never the
# NOT CERTIFIABLE form (which also prints "ACTION FLOOR: 2").
expect_guard_raised() { # label decision session
  expect_equal "$1: exit 1, classified tier 2" "1 EFFECTIVE TIER: 2 (classified)" "$readiness_status $(readiness_line "EFFECTIVE TIER:")"
  expect_equal "$1: certifiable" "CERTIFIABLE: YES" "$(readiness_line "CERTIFIABLE:")"
  expect_equal "$1: the event raises the action floor" "ACTION FLOOR: 2 (guard log: $2 [fixture-class] session $3)" "$(readiness_line "ACTION FLOOR:")"
}

# --- baseline: a genuinely tier-0 increment is READY: YES without an external reviewer
build_readiness_project tier0 null 0
run_readiness
expect_ready_yes "readiness tier 0"
expect_contains "readiness tier 0: trusted install" "TRUST: TRUSTED - ai-engineering $readiness_version at ${marketplace_commit:0:12}" "$readiness_output"
expect_equal "readiness tier 0: classified tier 0" "EFFECTIVE TIER: 0 (classified)" "$(readiness_line "EFFECTIVE TIER:")"
expect_contains "readiness tier 0: the gate ran from the base config" "GATE full: PASSED" "$readiness_output"
expect_contains "readiness tier 0: external review optional and not configured" "EXTERNAL REVIEW: NOT CONFIGURED (optional at tier 0)" "$readiness_output"
expect_contains "readiness tier 0: the anchor was found" "GUARD LOG: anchor at 2000-01-01T00:00:00Z; 0 raising event(s)" "$readiness_output"

# --- trust: each failure alone is NOT CERTIFIABLE, tier 2, READY NO
run_readiness "$plugin_directory/scripts/readiness.sh"
expect_not_certifiable "trust: running from the repository copy" "not running from the installed plugin"
expect_equal "trust: an untrusted install is reported" "TRUST: NOT CERTIFIABLE" "$(readiness_line "TRUST:")"
expect_equal "trust: no classifier runs without trust" "CLASSIFIER FLOOR: 2 (NOT CERTIFIABLE: no trusted classifier)" "$(readiness_line "CLASSIFIER FLOOR:")"
rm "$config_directory/plugins/installed_plugins.json"
run_readiness
expect_not_certifiable "trust: registry missing" "plugin registry is missing"
printf '{"plugins": [}\n' >"$config_directory/plugins/installed_plugins.json"
run_readiness
expect_not_certifiable "trust: registry malformed" "plugin registry is missing, unreadable or malformed"
write_registry "[$(user_entry), $(user_entry)]"
run_readiness
expect_not_certifiable "trust: two user installs are ambiguous" "more than one user-scope install"
write_registry "[$(user_entry | jq -c 'del(.gitCommitSha)')]"
run_readiness
expect_not_certifiable "trust: an entry missing its commit" "no valid ai-engineering@ai-engineering-system entries"
write_registry "[$(user_entry "$install_directory" 0.2.9)]"
run_readiness
expect_not_certifiable "trust: an installed version below 0.3.0" "older than 0.3.0"
write_registry "[$(user_entry "$install_directory" "$readiness_version" 0000000000000000000000000000000000000000)]"
run_readiness
expect_not_certifiable "trust: the recorded commit is not the tag" "does not resolve to the recorded commit"
write_registry "[$(user_entry), $(jq -n -c --arg p "$readiness_project" --arg c "$marketplace_commit" --arg v "$readiness_version" '{scope: "local", projectPath: $p, installPath: "/nonexistent/install", version: $v, gitCommitSha: $c}')]"
run_readiness
expect_not_certifiable "trust: a local-scope install for this project takes precedence" "installed plugin directory does not exist"
write_registry "[$(user_entry), $(jq -n -c --arg c "$marketplace_commit" --arg v "$readiness_version" '{scope: "local", projectPath: "/some/other/project", installPath: "/nonexistent/install", version: $v, gitCommitSha: $c}')]"
run_readiness
expect_ready_yes "trust: a local install for another project does not apply"
reset_trust
write_known v0.0.1
run_readiness
expect_not_certifiable "trust: the known marketplace source differs from the pin" "known marketplace source does not equal the project pin"
reset_trust
cp "$install_directory/skills/review/SKILL.md" "$readiness_root/review-backup.md"
printf 'tampered\n' >>"$install_directory/skills/review/SKILL.md"
run_readiness
expect_not_certifiable "trust: an installed file differs from the tag" "installed file differs from the tag: skills/review/SKILL.md"
cp "$readiness_root/review-backup.md" "$install_directory/skills/review/SKILL.md"
chmod +x "$install_directory/skills/review/SKILL.md"
run_readiness
expect_not_certifiable "trust: an installed file mode differs from the tag" "installed file mode differs from the tag: skills/review/SKILL.md"
chmod -x "$install_directory/skills/review/SKILL.md"
printf 'extra\n' >"$install_directory/scripts/extra.sh"
run_readiness
expect_not_certifiable "trust: an extra installed file" "files that are not in the tag"
rm "$install_directory/scripts/extra.sh"
ln -s "$install_directory/README.md" "$install_directory/scripts/linked.sh"
run_readiness
expect_not_certifiable "trust: a symbolic link in the install" "symbolic link"
rm "$install_directory/scripts/linked.sh"
run_readiness
expect_ready_yes "trust: restored fixtures are trusted again"

# --- guard log: anchors, exact exclusions, rotation, missing and malformed evidence
reset_guard_log
guard_event deny "rm -rf /tmp/x" other-session >>"$(guard_log_file)"
run_readiness
expect_equal "guard log: a deny after the anchor (other session) is classified, not uncertifiable" "1 EFFECTIVE TIER: 2 (classified)" "$readiness_status $(readiness_line "EFFECTIVE TIER:")"
expect_contains "guard log: the deny raises the action floor" "ACTION FLOOR: 2 (guard log: deny [fixture-class] session other-session)" "$readiness_output"
expect_contains "guard log: tier 2 needs external review, which is not configured" "external review is required at tier 2 and did not pass (NOT CONFIGURED)" "$readiness_output"
reset_guard_log
guard_event ask "git switch work/WORK-001-I1" coordinator >>"$(guard_log_file)"
guard_event ask "$start_command" coordinator >>"$(guard_log_file)"
run_readiness
expect_ready_yes "guard log: exact resume and repeated start confirmations are excluded"
expect_contains "guard log: two exclusions counted" "0 raising event(s), 2 excluded" "$readiness_output"
for near_miss in "git switch  work/WORK-001-I1" "$start_command " "git switch -c work/WORK-001-I1 origin/main" "git switch work/WORK-001-I2" "cd . && git switch work/WORK-001-I1" "git checkout work/WORK-001-I1" "git merge --no-edit work/WORK-001-I1-T1"; do
  reset_guard_log
  guard_event ask "$near_miss" coordinator >>"$(guard_log_file)"
  run_readiness
  expect_guard_raised "guard log: near miss '$near_miss'" ask coordinator
done
reset_guard_log
guard_event deny "git switch work/WORK-001-I1" coordinator >>"$(guard_log_file)"
run_readiness
expect_guard_raised "guard log: a denied resume command is not excluded" deny coordinator
ws_ready increment-worktree WORK-001 --inc I1 --branch work/WORK-001-I1-T1 >/dev/null
reset_guard_log
guard_event ask "git merge --no-edit work/WORK-001-I1-T1" coordinator >>"$(guard_log_file)"
run_readiness
expect_ready_yes "guard log: the exact merge of a recorded worktree branch is excluded"
reset_guard_log
guard_event deny "git merge --no-edit work/WORK-001-I1-T1" coordinator >>"$(guard_log_file)"
run_readiness
expect_guard_raised "guard log: a denied merge of a recorded worktree branch is not excluded" deny coordinator
reset_guard_log
guard_event ask "git merge --no-edit work/WORK-001-I1-T2" coordinator >>"$(guard_log_file)"
run_readiness
expect_guard_raised "guard log: a merge of an unrecorded branch" ask coordinator
# Line order, not the one-second timestamps, places an event after the anchor.
reset_guard_log
guard_event ask "git status" late-session 1999-01-01T00:00:00Z >>"$(guard_log_file)"
run_readiness
expect_guard_raised "guard log: a later line with an earlier timestamp still counts" ask late-session
mkdir -p "$readiness_project/.git/ai-engineering"
{
  guard_event ask "git status" early-session 2000-06-01T00:00:00Z
  guard_event ask "$start_command" coordinator 2000-01-01T00:00:00Z
} >"$(guard_log_file)"
run_readiness
expect_ready_yes "guard log: an earlier line with a later timestamp is before the anchor"
# Events before the anchor are outside the window; malformed lines there are ignored.
mkdir -p "$readiness_project/.git/ai-engineering"
{
  guard_event deny "rm -rf /" earlier-session 1999-12-31T23:59:59Z
  printf '{"truncated": \n'
  guard_event ask "$start_command" coordinator 2000-01-01T00:00:00Z
} >"$(guard_log_file)"
run_readiness
expect_ready_yes "guard log: events and malformed lines before the anchor are ignored"
reset_guard_log
printf 'not json\n' >>"$(guard_log_file)"
run_readiness
expect_not_certifiable "guard log: a malformed line after the anchor" "malformed line after the increment-start anchor"
reset_guard_log
printf '{"time": "2000-01-01T00:00:02Z", "decision": "ask"' >>"$(guard_log_file)"
run_readiness
expect_not_certifiable "guard log: a truncated final line after the anchor" "malformed line after the increment-start anchor"
reset_guard_log
printf '%s\n' '{"time": "2000-01-01T00:00:02Z", "decision": "allow", "classes": [], "commandSha256": "x"}' >>"$(guard_log_file)"
run_readiness
expect_not_certifiable "guard log: an event with an unknown decision" "malformed line after the increment-start anchor"
rm -rf "${readiness_project:?}/.git/ai-engineering"
run_readiness
expect_not_certifiable "guard log: no log directory" "the log directory is missing"
mkdir -p "$readiness_project/.git/ai-engineering"
run_readiness
expect_not_certifiable "guard log: no log file" "guard-log.jsonl is missing"
guard_event ask "git status" coordinator >"$(guard_log_file)"
run_readiness
expect_not_certifiable "guard log: no anchor" "no increment-start anchor"
guard_event ask "$start_command" coordinator 2999-01-01T00:00:00Z >"$(guard_log_file)"
run_readiness
expect_not_certifiable "guard log: an anchor later than activeAt" "no increment-start anchor"
guard_event ask "$(printf '%s' "$start_command" | sed 's/WORK-001-I1/WORK-001-I9/')" coordinator 2000-01-01T00:00:00Z >"$(guard_log_file)"
run_readiness
expect_not_certifiable "guard log: another increment's start is not this anchor" "no increment-start anchor"
reset_guard_log
mv "$(guard_log_file)" "$readiness_root/real-log.jsonl"
ln -s "$readiness_root/real-log.jsonl" "$(guard_log_file)"
run_readiness
expect_not_certifiable "guard log: a linked log file" "guard-log.jsonl is missing, unreadable or not a regular file"
rm "$(guard_log_file)"
# Rotation: the anchor in guard-log.jsonl.1 still anchors; events in the newer file count.
reset_guard_log
mv "$(guard_log_file)" "$(guard_log_file).1"
guard_event ask "git status" coordinator >"$(guard_log_file)"
run_readiness
expect_guard_raised "guard log rotation: an event after a rotated anchor" ask coordinator
reset_guard_log
mv "$(guard_log_file)" "$(guard_log_file).1"
: >"$(guard_log_file)"
run_readiness
expect_ready_yes "guard log rotation: a rotated anchor with nothing after it"
reset_guard_log
guard_event ask "git status" coordinator >"$(guard_log_file).1"
guard_event ask "git status" coordinator >"$(guard_log_file)"
run_readiness
expect_not_certifiable "guard log rotation: an anchor rotated away" "no increment-start anchor"
reset_guard_log
mkdir "$(guard_log_file).1"
run_readiness
expect_not_certifiable "guard log rotation: a rotated file that is not a regular file" "guard-log.jsonl.1 is unreadable or not a regular file"
reset_guard_log
head -c 2095000 /dev/zero | tr '\0' 'x' >>"$(guard_log_file)"
run_readiness
expect_not_certifiable "guard log: a log near the guard's drop size" "near the size at which the guard drops lines"
reset_guard_log

# --- action floor from a trigger-2 decision
ws_ready decision WORK-001 --trigger 2 --question "add a dependency?" --answer "yes" >/dev/null
run_readiness
expect_contains "action floor: a trigger-2 decision raises it" "ACTION FLOOR: 2 (trigger-2 decision(s) D1)" "$readiness_output"
expect_equal "action floor: classified tier 2" "EFFECTIVE TIER: 2 (classified)" "$(readiness_line "EFFECTIVE TIER:")"

# --- state, repository and evidence conditions
build_readiness_project tier0-state null 0
printf 'untracked\n' >"$readiness_project/notes.txt"
run_readiness
expect_not_certifiable "readiness: an untracked file" "uncommitted changes in the working tree (notes.txt)"
rm "$readiness_project/notes.txt"
readiness_git "$readiness_project" switch -q --detach HEAD
run_readiness
expect_not_certifiable "readiness: a detached HEAD" "HEAD is detached"
readiness_git "$readiness_project" switch -q work/WORK-001-I1
readiness_git "$readiness_project" symbolic-ref --delete refs/remotes/origin/HEAD
run_readiness
expect_not_certifiable "readiness: no origin/HEAD" "origin/HEAD is not set"
readiness_git "$readiness_project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
readiness_output="$(CLAUDE_CONFIG_DIR="$config_directory" "$installed_readiness" WORK-001 --inc I9 "$readiness_project" 2>&1)"
readiness_status=$?
expect_not_certifiable "readiness: an unknown increment" "increment I9 does not exist exactly once"
readiness_output="$(CLAUDE_CONFIG_DIR="$config_directory" "$installed_readiness" WORK-002 --inc I1 "$readiness_project" 2>&1)"
readiness_status=$?
expect_not_certifiable "readiness: standalone use without state" "no valid work-item state for WORK-002"
printf 'edited\n' >>"$readiness_project/.agents/specs/active/WORK-001.md"
readiness_git "$readiness_project" add -A .agents/specs/active/WORK-001.md
readiness_git "$readiness_project" commit -q -m "spec edit"
run_readiness
expect_not_certifiable "readiness: a spec changed since approval" "spec does not match its approved hash"
for bad_arguments in "" "WORK-1" "WORK-001" "WORK-001 --inc" "WORK-001 --inc ../x" "WORK-001 --inc I1 --bogus"; do
  # shellcheck disable=SC2086 # intentional word splitting of the table entry
  "$installed_readiness" $bad_arguments >/dev/null 2>&1
  expect_equal "readiness: usage error for '$bad_arguments'" 2 "$?"
done

build_readiness_project tier0-evidence null 0
commit_change README.md
run_readiness
expect_equal "evidence: QA for an older commit is stale" "1 QA (internal): STALE" "$readiness_status $(readiness_line "QA (internal):")"
record_review qa
run_readiness
expect_ready_yes "evidence: QA recorded for HEAD"
ws_ready evidence WORK-001 --inc I1 --kind review --result pass --sha "$(readiness_git "$readiness_project" rev-parse HEAD)" >/dev/null
run_readiness
expect_ready_yes "evidence: a later review without a reviewer does not replace QA"
ws_ready evidence WORK-001 --inc I1 --kind review --reviewer qa --result fail --sha "$(readiness_git "$readiness_project" rev-parse HEAD)" >/dev/null
run_readiness
expect_equal "evidence: the latest QA result failing is READY NO" "1 QA (internal): FAILED" "$readiness_status $(readiness_line "QA (internal):")"
record_review qa
ws_ready finding-add WORK-001 --finding F1 --source qa --severity low --summary "open" >/dev/null
run_readiness
expect_equal "records: an open finding is READY NO" "1" "$readiness_status"
expect_contains "records: the open finding is the reason" "1 open finding(s)" "$(readiness_line "READY:")"
ws_ready finding-fixed WORK-001 --finding F1 --sha "$(readiness_git "$readiness_project" rev-parse HEAD)" >/dev/null
ws_ready propose WORK-001 --question "also a CHANGELOG?" >/dev/null
run_readiness
expect_ready_yes "records: an open scope proposal is listed but does not block"
expect_contains "records: the proposal is listed" "OPEN DECISIONS AND PROPOSALS: D1 (proposal)" "$readiness_output"
ws_ready block WORK-001 --trigger 5 --question "which reading?" >/dev/null
run_readiness
expect_equal "records: a blocked item is READY NO" "1" "$readiness_status"
expect_contains "records: the open blocking decision is a reason" "1 open blocking decision(s)" "$(readiness_line "READY:")"

# --- effective tier: the state tier never lowers the classifier floor
build_readiness_project tier-floor null 0
commit_change package.json
record_review qa
run_readiness
expect_equal "effective tier: state tier 0 with classifier floor 2 is tier 2" "EFFECTIVE TIER: 2 (classified)" "$(readiness_line "EFFECTIVE TIER:")"
expect_contains "effective tier: the classifier names the dependency" "CLASSIFIER FLOOR: 2 (tier0:markdown, tier2:dependency)" "$readiness_output"
expect_contains "effective tier: tier 2 needs security evidence" "security review evidence covering HEAD is MISSING" "$(readiness_line "READY:")"
expect_contains "effective tier: tier 2 needs a residual-risk list" "the residual-risk list covering HEAD is MISSING" "$(readiness_line "READY:")"
expect_contains "effective tier: tier 2 needs external review" "external review is required at tier 2" "$(readiness_line "READY:")"

# --- tiers 1 and 2 with a configured external reviewer
build_readiness_project tier1-external '"true"' 1
run_readiness
expect_ready_yes "tier 1: READY YES with QA and a passing external review"
expect_contains "tier 1: external review required" "EXTERNAL REVIEW: PASSED (required at tier 1)" "$readiness_output"
expect_equal "tier 1: security review is a tier-2 requirement" "SECURITY REVIEW (internal): NOT REQUIRED at tier 1" "$(readiness_line "SECURITY REVIEW")"
build_readiness_project tier1-reviewer-error '"exit 7"' 1
run_readiness
expect_equal "tier 1: an external reviewer error is READY NO" "1" "$readiness_status"
expect_contains "tier 1: the reviewer error is the reason" "external review is required at tier 1 and did not pass (ERROR (reviewer exit 7))" "$(readiness_line "READY:")"
build_readiness_project tier1-unconfigured null 1
run_readiness
expect_equal "tier 1: NOT CONFIGURED external review is READY NO" "1" "$readiness_status"
expect_contains "tier 1: the external reason" "external review is required at tier 1 and did not pass (NOT CONFIGURED)" "$(readiness_line "READY:")"
build_readiness_project tier2-external '"true"' 0
commit_change package.json
record_review qa
record_review security
run_readiness
expect_equal "tier 2: READY NO without the residual-risk list" "1" "$readiness_status"
expect_contains "tier 2: the missing residual-risk list is the reason" "the residual-risk list covering HEAD is MISSING" "$(readiness_line "READY:")"
record_review residual-risks
run_readiness
expect_ready_yes "tier 2: READY YES with QA, security, residual risks and a passing external review"
ws_ready evidence WORK-001 --inc I1 --kind review --reviewer security --result fail --sha "$(readiness_git "$readiness_project" rev-parse HEAD)" >/dev/null
ws_ready evidence WORK-001 --inc I1 --kind residual-risks --result fail --sha "$(readiness_git "$readiness_project" rev-parse HEAD)" >/dev/null
run_readiness
expect_equal "tier 2: a failed security review" "SECURITY REVIEW (internal): FAILED" "$(readiness_line "SECURITY REVIEW")"
expect_equal "tier 2: a failed residual-risk list" "RESIDUAL RISKS: FAILED" "$(readiness_line "RESIDUAL RISKS:")"
record_review security
record_review residual-risks
commit_change package.json
record_review qa
run_readiness
expect_equal "tier 2: security evidence for an older commit is stale" "SECURITY REVIEW (internal): STALE" "$(readiness_line "SECURITY REVIEW")"
expect_equal "tier 2: a residual-risk list for an older commit is stale" "RESIDUAL RISKS: STALE" "$(readiness_line "RESIDUAL RISKS:")"
expect_equal "tier 2: stale evidence is READY NO, certifiable" "1 CERTIFIABLE: YES" "$readiness_status $(readiness_line "CERTIFIABLE:")"
build_readiness_project tier2-reviewer-fails '"exit 1"' 0
commit_change package.json
record_review qa
record_review security
record_review residual-risks
run_readiness
expect_contains "tier 2: blocking external findings are READY NO" "did not pass (BLOCKING FINDINGS)" "$(readiness_line "READY:")"
build_readiness_project gate-fails null 0 false
run_readiness
expect_equal "gate: a failing full gate is READY NO" "1" "$readiness_status"
expect_contains "gate: the failing verdict is reported" "GATE full: FAILED" "$readiness_output"
expect_contains "gate: the failure is a reason" "the full gate did not pass" "$(readiness_line "READY:")"
build_readiness_project gate-redefined null 0
jq '.full = "false"' "$readiness_project/.agents/gates.json" >"$readiness_root/gates.json"
cp "$readiness_root/gates.json" "$readiness_project/.agents/gates.json"
readiness_git "$readiness_project" add .agents/gates.json
readiness_git "$readiness_project" commit -q -m "gate on the branch only"
record_review qa
run_readiness
expect_contains "gate: the base gate certifies, not the branch's" "GATE full: PASSED" "$readiness_output"
expect_contains "gate: a change to the gate is READY NO" "the change modifies the full gate" "$(readiness_line "READY:")"
expect_contains "gate: the gate change is classified tier 2" "tier2:gates" "$(readiness_line "CLASSIFIER FLOOR:")"
build_readiness_project gate-unconfigured null 0 ""
run_readiness
expect_equal "gate: no full gate is READY NO, certifiable" "1 CERTIFIABLE: YES" "$readiness_status $(readiness_line "CERTIFIABLE:")"
expect_contains "gate: the missing gate is reported" "GATE full: NOT CONFIGURED" "$readiness_output"
build_readiness_project gate-forged null 0 'echo "GATE full: PASSED (exit 0) command: forged"; exit 1'
run_readiness
expect_contains "gate: a PASSED line printed by a failing gate is not the verdict" "GATE full: FAILED (exit 1)" "$(readiness_line "GATE full:")"
expect_contains "gate: the forged pass is READY NO" "the full gate did not pass" "$(readiness_line "READY:")"

# --- base (H1): the recorded base, never a moved default-branch ref
build_readiness_project base-moved null 0
base_moved_recorded="$(readiness_git "$readiness_project" rev-parse refs/remotes/origin/main)"
readiness_git "$readiness_project" update-ref refs/remotes/origin/main HEAD
run_readiness
expect_not_certifiable "base: origin/main moved to HEAD" "the default-branch ref changed after the increment began"
expect_equal "base: no gate runs against a moved ref" "GATE full: NOT RUN (no base commit)" "$(readiness_line "GATE full:")"
expect_equal "base: no classifier runs against a moved ref" "CLASSIFIER FLOOR: 2 (NOT CERTIFIABLE: no trusted classifier)" "$(readiness_line "CLASSIFIER FLOOR:")"
base_moved_newer="$(readiness_git "$readiness_project" commit-tree -p "$base_moved_recorded" -m newer "$base_moved_recorded^{tree}")"
readiness_git "$readiness_project" update-ref refs/remotes/origin/main "$base_moved_newer"
run_readiness
expect_not_certifiable "base: a newer default-branch commit is not accepted automatically" "a newer ref is never accepted automatically"
readiness_git "$readiness_project" update-ref refs/remotes/origin/main "$base_moved_recorded"
run_readiness
expect_ready_yes "base: the ref back at the recorded base"
expect_contains "base: the block names the recorded base" "BASE: $base_moved_recorded (recorded increment base; origin/main at $base_moved_recorded)" "$readiness_output"
ws_ready increment-set WORK-001 --inc I1 --base-sha "$base_moved_newer" >/dev/null 2>&1
expect_equal "base: workstate never replaces a recorded base" "$base_moved_recorded" "$(jq -r '.increments[0].baseSha' "$(readiness_state_file)")"
edit_readiness_state '.increments[0].baseSha = null'
run_readiness
expect_not_certifiable "base: no recorded base" "has no recorded base commit"
# A branch commit recorded as the base, with the ref moved to match: the branch reflog shows
# where the increment really began.
build_readiness_project base-forged null 0
base_forged_commit="$(readiness_git "$readiness_project" rev-parse HEAD)"
edit_readiness_state ".increments[0].baseSha = \"$base_forged_commit\""
readiness_git "$readiness_project" update-ref refs/remotes/origin/main "$base_forged_commit"
commit_change package.json
record_review qa
run_readiness
expect_not_certifiable "base: a recorded base the branch was not created from" "does not show it created from the recorded base"
build_readiness_project base-empty null 0
cp "$(readiness_state_file)" "$readiness_root/base-empty-state.json"
readiness_git "$readiness_project" reset -q --hard refs/remotes/origin/main
cp "$readiness_root/base-empty-state.json" "$(readiness_state_file)"
run_readiness
expect_equal "base: an increment with no commits is READY NO, certifiable" "1 CERTIFIABLE: YES" "$readiness_status $(readiness_line "CERTIFIABLE:")"
expect_contains "base: no commits is the reason" "the increment has no commits after its base" "$(readiness_line "READY:")"

# --- work-item records (M1): one validated snapshot; a failed read or a change is NOT CERTIFIABLE
build_readiness_project records-corrupt null 0
printf '{ not json' >"$(readiness_state_file)"
run_readiness
expect_not_certifiable "records: an unreadable state" "work-item records for WORK-001 could not be read and validated"
expect_equal "records: no records are not reported as zero findings" "OPEN FINDINGS: unknown (no records)" "$(readiness_line "OPEN FINDINGS:")"
printf '#!/bin/sh\nprintf x >>"%s"\n' "$readiness_root/records-changed/.agents/specs/active/WORK-001.state.json" >"$readiness_root/rewrite-state.sh"
build_readiness_project records-changed null 0 "sh '$readiness_root/rewrite-state.sh'"
ws_ready finding-add WORK-001 --finding F1 --source qa --severity low --summary "open" >/dev/null
run_readiness
expect_not_certifiable "records: a gate that rewrites the state while readiness runs" "the work-item state or spec changed while readiness ran"
expect_equal "records: the open finding still comes from the snapshot" "OPEN FINDINGS: 1" "$(readiness_line "OPEN FINDINGS:")"

# --- working tree (M2): hidden changes and an unreadable status fail closed
build_readiness_project tree-flags null 0
readiness_git "$readiness_project" update-index --skip-worktree README.md
printf 'module.exports = () => true;\n' >"$readiness_project/README.md"
run_readiness
expect_not_certifiable "working tree: a skip-worktree file" "tracked file README.md is marked assume-unchanged or skip-worktree"
readiness_git "$readiness_project" update-index --no-skip-worktree README.md
readiness_git "$readiness_project" checkout -q -- README.md
readiness_git "$readiness_project" update-index --assume-unchanged package.json
run_readiness
expect_not_certifiable "working tree: an assume-unchanged file" "tracked file package.json is marked assume-unchanged or skip-worktree"
readiness_git "$readiness_project" update-index --no-assume-unchanged package.json
cp "$readiness_project/.git/index" "$readiness_root/tree-flags-index"
printf 'garbage' >"$readiness_project/.git/index"
run_readiness
expect_not_certifiable "working tree: git status fails" "git status failed"
cp "$readiness_root/tree-flags-index" "$readiness_project/.git/index"
readiness_git "$readiness_project" mv README.md README.txt
run_readiness
expect_not_certifiable "working tree: a staged rename" "uncommitted changes in the working tree"
readiness_git "$readiness_project" mv README.txt README.md
run_readiness
expect_ready_yes "working tree: restored"

# --- full gate (M2): a fresh local clone at exactly HEAD, never the development checkout
# The gate checks, from inside, that it runs without readiness's two Git variables, on the
# clone's own branch at HEAD, with no remote and no copy of the increment branch. The temporary
# directory's path contains words that make the guard look Git state up ("checkout", "push").
# shellcheck disable=SC2016 # the gate command is run later by the gate, not by this shell
{
  gate_probe_command='test -z "${GIT_NO_REPLACE_OBJECTS+set}" && test -z "${GIT_NO_LAZY_FETCH+set}"'
  gate_probe_command="$gate_probe_command"' && test "$(git symbolic-ref HEAD)" = refs/heads/ai-engineering-readiness-gate'
  gate_probe_command="$gate_probe_command"' && test "$(git for-each-ref --format="%(refname)" refs/heads refs/remotes)" = refs/heads/ai-engineering-readiness-gate'
  gate_probe_command="$gate_probe_command"' && test ! -e local-only.txt && test -z "$(git remote)" && test -z "$(git status --porcelain)"'
  gate_probe_command="$gate_probe_command"' && git rev-parse HEAD >'"'$readiness_root/gate-head.txt'"' && pwd -P >'"'$readiness_root/gate-directory.txt'"' && touch gate-wrote.txt'
  gate_probe_command="$gate_probe_command"' && printf "%s" "$TMPDIR" >'"'$readiness_root/gate-tmpdir.txt'"
}
build_readiness_project gate-isolated null 0 "$gate_probe_command"
printf 'local-only.txt\n' >>"$readiness_project/.git/info/exclude"
printf 'ignored, untracked and only in the development checkout\n' >"$readiness_project/local-only.txt"
gate_tmp="$readiness_root/checkout-push-tmp"
mkdir -p "$gate_tmp"
TMPDIR="$gate_tmp" run_readiness
expect_ready_yes "gate isolation: under a temporary path with guard trigger words, the gate passes only in the clone"
expect_contains "gate isolation: the base-commit gate passed" "GATE full: PASSED (exit 0)" "$(readiness_line "GATE full:")"
expect_equal "gate isolation: the gate ran at exactly HEAD" "$(readiness_git "$readiness_project" rev-parse HEAD)" "$(cat "$readiness_root/gate-head.txt" 2>/dev/null)"
case "$(cat "$readiness_root/gate-directory.txt" 2>/dev/null)" in
  "$(cd "$gate_tmp" && pwd -P)/"*) pass ;;
  *) fail "gate isolation: the gate ran in a temporary clone (got '$(cat "$readiness_root/gate-directory.txt" 2>/dev/null)')" ;;
esac
case "$(cat "$readiness_root/gate-tmpdir.txt" 2>/dev/null)" in
  "$gate_tmp/readiness-clone."*/tmp) pass ;;
  *) fail "gate isolation: the gate's TMPDIR is private to its clone root (got '$(cat "$readiness_root/gate-tmpdir.txt" 2>/dev/null)')" ;;
esac
if [ -e "$readiness_project/gate-wrote.txt" ]; then fail "gate isolation: the gate wrote into the development checkout"; else pass; fi
expect_equal "gate isolation: the temporary clone is removed" "" "$(ls -A "$gate_tmp")"
expect_equal "gate isolation: the clone's branch never reaches the development repository" "" "$(readiness_git "$readiness_project" for-each-ref refs/heads/ai-engineering-readiness-gate)"
# A replace ref could show the external review other objects than readiness reads.
readiness_git "$readiness_project" replace "$(readiness_git "$readiness_project" rev-parse HEAD)" "$(readiness_git "$readiness_project" rev-parse HEAD~1)"
run_readiness
expect_not_certifiable "gate isolation: a replace ref in the repository" "the repository has replace refs"
readiness_git "$readiness_project" replace -d "$(readiness_git "$readiness_project" rev-parse HEAD)" >/dev/null
# The guard still refuses an unsafe gate command inside the clone.
build_readiness_project gate-unsafe null 0 "terraform apply -auto-approve"
run_readiness
expect_contains "gate: the guard still refuses a high-impact gate in the clone" "GATE full: REFUSED" "$(readiness_line "GATE full:")"
expect_equal "gate: a refused gate is READY NO, certifiable" "1 CERTIFIABLE: YES" "$readiness_status $(readiness_line "CERTIFIABLE:")"
expect_equal "gate isolation: the development checkout is unchanged" "" "$(readiness_git "$readiness_project" status --porcelain=v1 --untracked-files=all -- . ':!.agents/specs/active/WORK-001.state.json')"

# --- external review at tier 0 (M3): optional when not configured, never ignored when configured
build_readiness_project tier0-reviewer-blocks '"exit 1"' 0
run_readiness
expect_equal "tier 0: a configured reviewer's blocking findings are READY NO" "1 EFFECTIVE TIER: 0 (classified)" "$readiness_status $(readiness_line "EFFECTIVE TIER:")"
expect_contains "tier 0: the blocking findings are the reason" "the configured external review did not pass (BLOCKING FINDINGS)" "$(readiness_line "READY:")"
build_readiness_project tier0-reviewer-error '"exit 7"' 0
run_readiness
expect_contains "tier 0: a configured reviewer's error is READY NO" "the configured external review did not pass (ERROR (reviewer exit 7))" "$(readiness_line "READY:")"
build_readiness_project tier0-reviewer-passes '"true"' 0
run_readiness
expect_ready_yes "tier 0: a configured reviewer that passes"

# --- more trust cells, branch identity, report lines and classifier floor 1
build_readiness_project trust-cells null 0
rm "$config_directory/plugins/known_marketplaces.json"
run_readiness
expect_not_certifiable "trust: known marketplaces missing" "known-marketplaces record is missing"
printf '{"ai-engineering-system": \n' >"$config_directory/plugins/known_marketplaces.json"
run_readiness
expect_not_certifiable "trust: known marketplaces malformed" "known-marketplaces record is missing, unreadable or malformed"
write_known "v$readiness_version" "$readiness_root/no-such-clone"
run_readiness
expect_not_certifiable "trust: the marketplace clone is missing" "the marketplace clone does not exist"
reset_trust
readiness_git "$marketplace_clone" tag -d "v$readiness_version" >/dev/null
run_readiness
expect_not_certifiable "trust: the release tag is missing" "does not resolve to the recorded commit"
readiness_git "$marketplace_clone" tag "v$readiness_version" "$marketplace_commit"
write_registry "[$(user_entry "$install_directory" 9.9.9)]"
run_readiness
expect_not_certifiable "trust: the registry version differs from plugin.json" "installed plugin.json does not report version 9.9.9"
write_registry "[$(user_entry), $(jq -n -c --arg p "$readiness_project" --arg c "$marketplace_commit" --arg v "$readiness_version" '{scope: "project", projectPath: $p, installPath: "/nonexistent/install", version: $v, gitCommitSha: $c}')]"
run_readiness
expect_not_certifiable "trust: a project-scope install for this project takes precedence" "installed plugin directory does not exist"
local_entry="$(jq -n -c --arg p "$readiness_project" --arg i "$install_directory" --arg c "$marketplace_commit" --arg v "$readiness_version" '{scope: "local", projectPath: $p, installPath: $i, version: $v, gitCommitSha: $c}')"
write_registry "[$local_entry, $local_entry]"
run_readiness
expect_not_certifiable "trust: two local installs for this project are ambiguous" "more than one local-scope install"
reset_trust
run_readiness
expect_ready_yes "trust: restored again"
readiness_git "$readiness_project" switch -q -c other-branch
run_readiness
expect_not_certifiable "branch: a checked-out branch other than the recorded one" "the checked-out branch is not increment I1's recorded branch"
readiness_git "$readiness_project" switch -q work/WORK-001-I1
ws_ready increment-worktree WORK-001 --inc I1 --branch main >/dev/null
run_readiness
expect_not_certifiable "branch: a worktree branch named like the default branch" "recorded worktree branch main is not a plain local work branch"
build_readiness_project report-lines null 0
ws_ready finding-add WORK-001 --finding F1 --source security-reviewer --severity high --summary "fixed high" --security >/dev/null
ws_ready finding-fixed WORK-001 --finding F1 --sha "$(readiness_git "$readiness_project" rev-parse HEAD)" >/dev/null
ws_ready decision WORK-001 --trigger 1 --question "wording?" --answer "plain" >/dev/null
ws_ready owner-action-add WORK-001 --action-id A1 --description "sign in" --increment I1 >/dev/null
run_readiness
expect_equal "report: fixed high findings" "HIGH-OR-ABOVE FIXES: F1" "$(readiness_line "HIGH-OR-ABOVE FIXES:")"
expect_equal "report: conversation decisions" "CONVERSATION DECISIONS: D1" "$(readiness_line "CONVERSATION DECISIONS:")"
expect_equal "report: owner-command risk decisions" "OWNER-COMMAND RISK DECISIONS: none" "$(readiness_line "OWNER-COMMAND RISK DECISIONS:")"
expect_equal "report: pending owner actions" "PENDING OWNER ACTIONS: A1" "$(readiness_line "PENDING OWNER ACTIONS:")"
expect_equal "report: no open findings" "OPEN FINDINGS: 0" "$(readiness_line "OPEN FINDINGS:")"
build_readiness_project classifier-floor-1 null 0
printf 'notes\n' >"$readiness_project/notes.txt"
readiness_git "$readiness_project" add notes.txt
readiness_git "$readiness_project" commit -q -m notes
record_review qa
run_readiness
expect_equal "effective tier: classifier floor 1 over state tier 0" "EFFECTIVE TIER: 1 (classified)" "$(readiness_line "EFFECTIVE TIER:")"
expect_contains "effective tier: tier 1 needs external review" "external review is required at tier 1" "$(readiness_line "READY:")"

# --- pins
readiness_pin_ref=v0.0.9
build_readiness_project pin-mismatch null 0
run_readiness
expect_not_certifiable "pin: a pin that names another ref" "the base-commit pin does not name ref v$readiness_version"
readiness_pin_ref=none
build_readiness_project pin-missing null 0
run_readiness
expect_not_certifiable "pin: no project settings at the base commit" "no .claude/settings.json at the base commit"
readiness_pin_ref=""

# --- evidence covering HEAD: renames are not detected, so a hidden deletion is stale
build_readiness_project evidence-rename null 0
readiness_git "$readiness_project" mv package.json .agents/specs/active/WORK-001.log.md
readiness_git "$readiness_project" commit -q -m "rename into the log"
run_readiness
expect_equal "evidence: a rename into a bookkeeping path is not covered" "QA (internal): STALE" "$(readiness_line "QA (internal):")"

# --- hashes that cannot be computed (L3): a stand-in that returns nothing for command text only
hash_stand_in="$readiness_root/hash-stand-in"
mkdir -p "$hash_stand_in"
for hash_tool in shasum sha256sum; do
  real_hash_tool="$(command -v "$hash_tool" || true)"
  [ -n "$real_hash_tool" ] || continue
  cat >"$hash_stand_in/$hash_tool" <<STANDIN
#!/bin/bash
# Test stand-in: a file argument hashes normally; standard input hashes normally unless it is
# command text ("git ..."), which hashes to nothing.
if [ \$# -gt 0 ]; then
  last_argument="\${*: -1}"
  if [ "\$last_argument" != 256 ] && [ "\${last_argument#-}" = "\$last_argument" ]; then exec "$real_hash_tool" "\$@"; fi
fi
input_file="\$(mktemp)"
trap 'rm -f "\$input_file"' EXIT
cat >"\$input_file"
if [ "\$(head -c 4 "\$input_file")" = "git " ]; then exit 0; fi
"$real_hash_tool" "\$@" <"\$input_file"
STANDIN
  chmod +x "$hash_stand_in/$hash_tool"
done
build_readiness_project hash-failure null 0
PATH="$hash_stand_in:$PATH" run_readiness
expect_not_certifiable "guard log: hashes that cannot be computed" "the exact-command hashes could not be computed"

# --- the real guard writes the log readiness reads (no fixture log lines)
readiness_real_guard=yes
build_readiness_project real-guard null 0
readiness_real_guard=no
expect_equal "real guard: the start confirmation was logged with the exact command's hash" "ask $(text_sha256 "$start_command")" \
  "$(head -n 1 "$(guard_log_file)" 2>/dev/null | jq -r '"\(.decision) \(.commandSha256)"')"
run_readiness
expect_ready_yes "real guard: the guard's own start confirmation anchors the increment"
real_guard "git switch work/WORK-001-I1"
ws_ready increment-worktree WORK-001 --inc I1 --branch work/WORK-001-I1-T1 >/dev/null
real_guard "git merge --no-edit work/WORK-001-I1-T1"
run_readiness
expect_ready_yes "real guard: exact resume and recorded worktree merge confirmations"
expect_contains "real guard: both are excluded" "0 raising event(s), 2 excluded" "$readiness_output"
real_guard "git pull" other-real-session
run_readiness
expect_equal "real guard: another session's prompt is classified tier 2" "1 EFFECTIVE TIER: 2 (classified)" "$readiness_status $(readiness_line "EFFECTIVE TIER:")"
expect_contains "real guard: the other session raises the floor" "session other-real-session" "$(readiness_line "ACTION FLOOR:")"

# --- H1 path B: the owner-approved start command must name the recorded base commit
build_readiness_project start-names-base null 0
rm -rf "${readiness_project:?}/.git/ai-engineering"
mkdir -p "$readiness_project/.git/ai-engineering"
guard_event ask "git switch -c work/WORK-001-I1 origin/main" coordinator 2000-01-01T00:00:00Z >"$(guard_log_file)"
run_readiness
expect_not_certifiable "base: a start command that does not name the base is no anchor" "no increment-start anchor (git switch -c work/WORK-001-I1 $readiness_base)"
guard_event ask "git switch -c work/WORK-001-I1 1111111111111111111111111111111111111111" coordinator 2000-01-01T00:00:00Z >"$(guard_log_file)"
run_readiness
expect_not_certifiable "base: a start command naming another commit is no anchor" "no increment-start anchor"
reset_guard_log
run_readiness
expect_ready_yes "base: the start command naming the recorded base anchors"
# A default-branch ref planted before the start. Workstate accepts only what origin/main names at
# that moment, and the start command names that commit, but an ask record proves neither the
# owner's approval nor that the command ran, and nothing local authenticates the remote. This is
# the open trust-boundary gap (closing it needs separate guard evidence): readiness still
# certifies, and this test records that outcome so a change to it is deliberate.
readiness_plant_base=yes
build_readiness_project base-planted null 0
readiness_plant_base=no
expect_equal "base: a planted base is what the start command names" \
  "git switch -c work/WORK-001-I1 $readiness_base" "$start_command"
if [ "$readiness_base" = "$(git --git-dir="$readiness_root/base-planted.git" rev-parse main)" ]; then
  fail "base: the planted fixture differs from the remote's main"
else pass; fi
run_readiness
expect_ready_yes "base (open gap, see the trust boundary): a base planted before the start still certifies"

# --- H1 path A: a renamed and recreated branch cannot substitute another starting point
build_readiness_project base-recreated null 0
base_substitute="$(readiness_git "$readiness_project" commit-tree -p "$readiness_base" -m substitute "$readiness_base^{tree}")"
readiness_git "$readiness_project" branch -m work/WORK-001-I1 old-work
readiness_git "$readiness_project" branch work/WORK-001-I1 "$base_substitute"
readiness_git "$readiness_project" switch -q work/WORK-001-I1
record_review qa
run_readiness
expect_not_certifiable "base: a recreated increment branch" "does not show it created from the recorded base"

# --- external review: its own clone, the intended commits, no repository-controlled diff behaviour
# shellcheck disable=SC2016 # the reviewer command is run later by external-review.sh
review_probe='git rev-parse --verify -q "$REVIEW_BASE_REF^{commit}" >/dev/null && test "$REVIEW_HEAD_REF" = "$(git rev-parse HEAD)" && printf "%s %s" "$REVIEW_BASE_REF" "$REVIEW_HEAD_REF" >'"'$readiness_root/review-refs.txt'"' && git diff "$REVIEW_BASE_REF" "$REVIEW_HEAD_REF" -- README.md >'"'$readiness_root/review-diff.txt'"' && grep -q "^+payload-marker" '"'$readiness_root/review-diff.txt'"' && grep -q "^+++ b/README.md" '"'$readiness_root/review-diff.txt'"
build_readiness_project review-diff "$(jq -n --arg command "$review_probe" '$command')" 0
printf 'payload-marker\n' >>"$readiness_project/README.md"
readiness_git "$readiness_project" add README.md
readiness_git "$readiness_project" commit -q -m payload
record_review qa
run_readiness
expect_ready_yes "external review: the reviewer sees the payload in its own clone"
expect_equal "external review: the reviewer receives the recorded base and HEAD" \
  "$readiness_base $(readiness_git "$readiness_project" rev-parse HEAD)" "$(cat "$readiness_root/review-refs.txt" 2>/dev/null)"
GIT_EXTERNAL_DIFF=true run_readiness
expect_ready_yes "external review: an inherited GIT_EXTERNAL_DIFF is removed"
# Settings of the development repository do not reach the reviewer's fresh clone.
readiness_git "$readiness_project" config diff.external true
readiness_git "$readiness_project" config core.bigFileThreshold 1
run_readiness
expect_ready_yes "external review: the development repository's diff settings do not reach the clone"
readiness_git "$readiness_project" config --unset diff.external
readiness_git "$readiness_project" config --unset core.bigFileThreshold
# User-level settings (a fixture HOME) that would blind the reviewer are neutralised in the clone.
review_home() { # name: a fixture HOME with its own Git configuration and attributes directory
  mkdir -p "$readiness_root/home-$1/.config/git"
  printf '[user]\n\tname = test\n\temail = test@example.com\n' >"$readiness_root/home-$1/.gitconfig"
  printf '%s' "$readiness_root/home-$1"
}
blind_home="$(review_home big-file)"
printf '[core]\n\tbigFileThreshold = 1\n' >>"$blind_home/.gitconfig"
HOME="$blind_home" XDG_CONFIG_HOME="$blind_home/.config" run_readiness
expect_ready_yes "external review: a user-level core.bigFileThreshold (binary diffs) is neutralised"
blind_home="$(review_home xdg-attributes)"
printf '* -diff\n' >"$blind_home/.config/git/attributes"
HOME="$blind_home" XDG_CONFIG_HOME="$blind_home/.config" run_readiness
expect_ready_yes "external review: a user-level attributes file with -diff is neutralised"
blind_home="$(review_home prefixes)"
printf '[diff]\n\tnoprefix = true\n\tdstPrefix = b/docs/\n\trelative = true\n' >>"$blind_home/.gitconfig"
HOME="$blind_home" XDG_CONFIG_HOME="$blind_home/.config" run_readiness
expect_ready_yes "external review: user-level diff path prefixes are neutralised"
blind_home="$(review_home template)"
mkdir -p "$blind_home/template/info"
printf '* -diff\n' >"$blind_home/template/info/attributes"
printf '[init]\n\ttemplateDir = %s\n' "$blind_home/template" >>"$blind_home/.gitconfig"
HOME="$blind_home" XDG_CONFIG_HOME="$blind_home/.config" run_readiness
expect_ready_yes "external review: a user-level template with info/attributes is not used"
GIT_TEMPLATE_DIR="$blind_home/template" run_readiness
expect_ready_yes "external review: an inherited GIT_TEMPLATE_DIR is removed"
blind_home="$(review_home external-diff)"
printf '[diff]\n\texternal = true\n' >>"$blind_home/.gitconfig"
HOME="$blind_home" XDG_CONFIG_HOME="$blind_home/.config" run_readiness
expect_not_certifiable "external review: a user-level diff.external cannot be neutralised" "diff.external is set in the user or system Git configuration and cannot be neutralised"
expect_equal "external review: not run when its diff cannot be trusted" "EXTERNAL REVIEW: NOT RUN (the reviewer's diff cannot be trusted) (optional at tier 0)" "$(readiness_line "EXTERNAL REVIEW:")"
blind_home="$(review_home textconv)"
printf '[diff "hide"]\n\ttextconv = true\n' >>"$blind_home/.gitconfig"
HOME="$blind_home" XDG_CONFIG_HOME="$blind_home/.config" run_readiness
expect_ready_yes "external review: a user-level textconv driver that no changed file uses"
# Repository-controlled diff behaviour: a committed .gitattributes in HEAD.
printf 'README.md diff=hide\n' >"$readiness_project/.gitattributes"
readiness_git "$readiness_project" add .gitattributes
readiness_git "$readiness_project" commit -q -m "attributes: diff driver"
record_review qa
HOME="$blind_home" XDG_CONFIG_HOME="$blind_home/.config" run_readiness
expect_not_certifiable "external review: a changed file's diff driver with textconv" "README.md uses diff driver hide with diff.hide.textconv set"
printf 'README.md -diff\n' >"$readiness_project/.gitattributes"
readiness_git "$readiness_project" add .gitattributes
readiness_git "$readiness_project" commit -q -m "attributes: hide"
record_review qa
run_readiness
expect_not_certifiable "external review: a committed -diff on a changed text file" "README.md (text) has the -diff attribute"
printf 'README.md binary\n' >"$readiness_project/.gitattributes"
readiness_git "$readiness_project" add .gitattributes
readiness_git "$readiness_project" commit -q -m "attributes: binary"
record_review qa
run_readiness
expect_not_certifiable "external review: a committed binary attribute (which implies -diff) on a changed text file" "README.md (text) has the -diff attribute"

# --- tampering by the gate: everything readiness relied on is checked again afterwards
build_readiness_project gate-tamper null 0 "sh '$readiness_root/gate-action.sh'"
gate_tamper_project="$readiness_project"
set_gate_action() { printf '#!/bin/sh\n%s\n' "$1" >"$readiness_root/gate-action.sh"; }
set_gate_action "git -C '$gate_tamper_project' replace \"\$(git -C '$gate_tamper_project' rev-parse HEAD)\" \"\$(git -C '$gate_tamper_project' rev-parse HEAD~1)\""
run_readiness
expect_not_certifiable "gate tampering: a replace ref added by the gate" "replace refs"
expect_contains "gate tampering: found after the gate" "(after the gate)" "$(readiness_line "CERTIFIABLE:")"
readiness_git "$gate_tamper_project" replace -d "$(readiness_git "$gate_tamper_project" rev-parse HEAD)" >/dev/null
set_gate_action "git -C '$gate_tamper_project' update-ref refs/remotes/origin/main HEAD"
run_readiness
expect_not_certifiable "gate tampering: the default-branch ref moved by the gate" "origin/main moved while readiness ran"
readiness_git "$gate_tamper_project" update-ref refs/remotes/origin/main "$readiness_base"
set_gate_action "printf 'x\\n' >>'$install_directory/skills/review/SKILL.md'"
run_readiness
expect_not_certifiable "gate tampering: the installed plugin edited by the gate" "the installed plugin no longer matches its release tag after the gate"
cp "$readiness_root/review-backup.md" "$install_directory/skills/review/SKILL.md"
gate_tamper_head="$(readiness_git "$gate_tamper_project" rev-parse HEAD)"
set_gate_action "git -C '$gate_tamper_project' -c user.name=t -c user.email=t@e commit -q --allow-empty -m moved"
run_readiness
expect_not_certifiable "gate tampering: HEAD moved by the gate" "HEAD moved while readiness ran"
readiness_git "$gate_tamper_project" reset -q --soft "$gate_tamper_head"
set_gate_action "git -C '$gate_tamper_project' switch -q -c gate-side-branch"
run_readiness
expect_not_certifiable "gate tampering: the checked-out branch changed by the gate" "the checked-out branch changed while readiness ran"
readiness_git "$gate_tamper_project" switch -q work/WORK-001-I1
readiness_git "$gate_tamper_project" branch -q -D gate-side-branch
cp "$gate_tamper_project/.agents/specs/active/WORK-001.md" "$readiness_root/gate-tamper-spec.md"
set_gate_action "printf 'x\\n' >>'$gate_tamper_project/.agents/specs/active/WORK-001.md'"
run_readiness
expect_not_certifiable "gate tampering: the spec changed by the gate" "the work-item state or spec changed while readiness ran"
cp "$readiness_root/gate-tamper-spec.md" "$gate_tamper_project/.agents/specs/active/WORK-001.md"
# The gate rewrites the running readiness.sh in place (same inode) to print READY: YES. Readiness
# was parsed before the gate ran, so the checks after it still run and find the changed install.
cp "$install_directory/scripts/readiness.sh" "$readiness_root/readiness-backup.sh"
set_gate_action "printf '#!/bin/bash\\necho \"READY: YES\"\\nexit 0\\n' 1<>'$install_directory/scripts/readiness.sh'"
run_readiness
expect_not_certifiable "gate tampering: readiness.sh rewritten while it runs" "the installed plugin no longer matches its release tag after the gate"
cp "$readiness_root/readiness-backup.sh" "$install_directory/scripts/readiness.sh"
cp "$(readiness_state_file)" "$readiness_root/gate-tamper-state.json"
set_gate_action "printf 'x' >>'$gate_tamper_project/.agents/specs/active/WORK-001.state.json'"
run_readiness
expect_not_certifiable "gate tampering: the state rewritten by the gate" "the work-item state or spec changed while readiness ran"
cp "$readiness_root/gate-tamper-state.json" "$(readiness_state_file)"
set_gate_action ":"
run_readiness
expect_ready_yes "gate tampering: a gate that changes nothing"
# A gate that kills run-gate.sh leaves no verdict.
# The gate walks up its own process ancestry, stopping at readiness.sh, and kills the outermost
# run-gate.sh that readiness started on its gate clone (the subshell run-gate.sh forks shows the
# same command line). Nothing above readiness, such as a gate running this suite, is touched.
# shellcheck disable=SC2016 # the gate script's own text, expanded when it runs
set_gate_action 'process=$PPID; outermost=""
while [ "${process:-1}" -gt 1 ]; do
  command_line="$(ps -o command= -p "$process")"
  case "$command_line" in
    *readiness.sh*) break ;;
    *"run-gate.sh full "*"/gate-tree "*) outermost="$process" ;;
  esac
  process="$(ps -o ppid= -p "$process" | tr -d " ")"
done
[ -n "$outermost" ] && kill -KILL "$outermost"'
run_readiness
expect_contains "gate: no verdict when run-gate.sh is killed" "GATE full: NO VERDICT (run-gate.sh exit" "$(readiness_line "GATE full:")"
expect_equal "gate: no verdict is READY NO, certifiable" "1 CERTIFIABLE: YES" "$readiness_status $(readiness_line "CERTIFIABLE:")"

# --- the guard log rotated between its two reads (a stand-in cat rotates it after one read)
cat_stand_in="$readiness_root/cat-stand-in"
mkdir -p "$cat_stand_in"
real_cat="$(command -v cat)"
printf '%s\n' '#!/bin/bash' \
  "if [ \$# -eq 1 ] && [ \"\${1##*/}\" = guard-log.jsonl ] && [ ! -e '$readiness_root/rotated-once' ]; then" \
  "  '$real_cat' \"\$1\"; status=\$?; : >'$readiness_root/rotated-once'; mv \"\$1\" \"\$1.1\"; : >\"\$1\"; exit \$status" \
  'fi' \
  "exec '$real_cat' \"\$@\"" >"$cat_stand_in/cat"
chmod +x "$cat_stand_in/cat"
build_readiness_project log-rotation null 0
guard_event ask "git status" other-session >>"$(guard_log_file)"
PATH="$cat_stand_in:$PATH" run_readiness
expect_not_certifiable "guard log: rotated between its two reads" "the log was rotated or replaced while it was being read"
rm -f "$readiness_root/rotated-once"

# --- more negative cells
edit_readiness_state '.decisions += [{id: "", trigger: 2, question: "q", options: [], askedAt: "2000-01-01T00:00:00Z", answeredAt: "2000-01-01T00:00:00Z", answer: "a", source: "conversation", by: null, blocking: false}]'
reset_guard_log
run_readiness
expect_equal "action floor: a trigger-2 decision with an empty id still raises it" "ACTION FLOOR: 2 (trigger-2 decision(s) (no id))" "$(readiness_line "ACTION FLOOR:")"
expect_equal "action floor: the empty-id decision is a classified tier 2" "1 EFFECTIVE TIER: 2 (classified)" "$readiness_status $(readiness_line "EFFECTIVE TIER:")"
build_readiness_project negative-cells null 0
edit_readiness_state '.increments[0].evidence = []'
run_readiness
expect_equal "evidence: no QA evidence" "QA (internal): MISSING" "$(readiness_line "QA (internal):")"
expect_contains "evidence: missing QA is the reason" "QA evidence covering HEAD is MISSING" "$(readiness_line "READY:")"
record_review qa
chmod 000 "$(guard_log_file)"
if [ -r "$(guard_log_file)" ]; then skip "guard log: an unreadable log (this user can read a mode-000 file)"; else
  run_readiness
  expect_not_certifiable "guard log: an unreadable log" "guard-log.jsonl is missing, unreadable or not a regular file"
fi
chmod 600 "$(guard_log_file)"
mv "$readiness_project/.git/ai-engineering" "$readiness_project/.git/ai-engineering-real"
ln -s "$readiness_project/.git/ai-engineering-real" "$readiness_project/.git/ai-engineering"
run_readiness
expect_not_certifiable "guard log: a linked log directory" "the log directory is missing or a link"
rm "$readiness_project/.git/ai-engineering"
mv "$readiness_project/.git/ai-engineering-real" "$readiness_project/.git/ai-engineering"
ln -s "$(guard_log_file)" "$(guard_log_file).1"
run_readiness
expect_not_certifiable "guard log: a linked rotated log" "guard-log.jsonl.1 is unreadable or not a regular file"
rm "$(guard_log_file).1"
git_stand_in="$readiness_root/git-stand-in"
mkdir -p "$git_stand_in"
# shellcheck disable=SC2016 # the stand-in script's own text, expanded when it runs
printf '%s\n' '#!/bin/bash' 'for argument in "$@"; do [ "$argument" = clone ] && exit 128; done' "exec '$(command -v git)' \"\$@\"" >"$git_stand_in/git"
chmod +x "$git_stand_in/git"
PATH="$git_stand_in:$PATH" run_readiness
expect_not_certifiable "clones: the external review's clone cannot be created" "the external review could not run: a fresh clone of HEAD could not be created and verified"
expect_equal "clones: then the gate is not run" "GATE full: NOT RUN (not certifiable)" "$(readiness_line "GATE full:")"
run_readiness
expect_ready_yes "negative cells: restored"
build_readiness_project tier2-reviewer-error '"exit 7"' 0
commit_change package.json
record_review qa
run_readiness
expect_contains "tier 2: an external reviewer error is READY NO" "external review is required at tier 2 and did not pass (ERROR (reviewer exit 7))" "$(readiness_line "READY:")"

# --- locale: readiness parses with LC_ALL=C whatever the caller's locale; the gate gets the
# caller's locale back. A stand-in jq records the locale each of readiness's jq calls sees.
locale_stand_in="$readiness_root/locale-stand-in"
mkdir -p "$locale_stand_in"
printf '%s\n' '#!/bin/bash' "printf '%s\\n' \"\${LC_ALL-unset}\" >>'$readiness_root/jq-locales'" "exec '$(command -v jq)' \"\$@\"" >"$locale_stand_in/jq"
chmod +x "$locale_stand_in/jq"
build_readiness_project locale null 0 "test \"\${LC_ALL-}\" = POSIX"
: >"$readiness_root/jq-locales"
PATH="$locale_stand_in:$PATH" LC_ALL=POSIX run_readiness
expect_ready_yes "locale: the gate gets the caller's locale (POSIX) back"
expect_equal "locale: every jq call readiness makes runs with LC_ALL=C" "C" "$(sort -u "$readiness_root/jq-locales" | grep -v '^POSIX$' | tr '\n' ' ' | sed 's/ $//')"
if grep -qx POSIX "$readiness_root/jq-locales"; then pass; else fail "locale: the gate's and reviewer's own jq calls did not get the caller's locale (POSIX)"; fi

# --- the gate's checkout: user-level filters, attributes and templates cannot alter it
# A committed gate script ends in "exit 1"; a user-level smudge filter would turn it into
# "exit 0" (and its clean filter back, so git status stays clean) if checkout applied it.
build_readiness_project forged-gate '"true"' 0 "sh gate.sh"
printf 'echo running the real check\nexit 1\n' >"$readiness_project/gate.sh"
readiness_git "$readiness_project" add gate.sh
readiness_git "$readiness_project" commit -q -m "gate script"
record_review qa
forge_filter="[filter \"forge\"]
	smudge = sed 's/exit 1/exit 0/'
	clean = sed 's/exit 0/exit 1/'"
forge_home="$(review_home forge-attributes)"
printf '%s\n' "$forge_filter" >>"$forge_home/.gitconfig"
printf 'gate.sh filter=forge\n' >"$forge_home/.config/git/attributes"
HOME="$forge_home" XDG_CONFIG_HOME="$forge_home/.config" run_readiness
expect_contains "forged gate: a user-level smudge filter does not reach the gate's checkout" "GATE full: FAILED (exit 1)" "$(readiness_line "GATE full:")"
expect_equal "forged gate: READY NO, certifiable" "1 CERTIFIABLE: YES" "$readiness_status $(readiness_line "CERTIFIABLE:")"
forge_home="$(review_home forge-template)"
printf '%s\n' "$forge_filter" >>"$forge_home/.gitconfig"
mkdir -p "$forge_home/template/info"
printf 'gate.sh filter=forge\n' >"$forge_home/template/info/attributes"
printf '[init]\n\ttemplateDir = %s\n' "$forge_home/template" >>"$forge_home/.gitconfig"
HOME="$forge_home" XDG_CONFIG_HOME="$forge_home/.config" run_readiness
expect_contains "forged gate: a user-level template with attributes does not reach the gate's checkout" "GATE full: FAILED (exit 1)" "$(readiness_line "GATE full:")"

# --- time limits, termination and skipping
build_readiness_project gate-timeout null 0 "sleep 30"
mkdir -p "$readiness_root/timeout-tmp"
READINESS_GATE_TIMEOUT_SECONDS=2 TMPDIR="$readiness_root/timeout-tmp" run_readiness
expect_contains "time limits: a gate past its limit is stopped" "GATE full: TIMED OUT (after 2 s; stopped, exit" "$(readiness_line "GATE full:")"
expect_equal "time limits: a gate timeout is READY NO, certifiable" "1 CERTIFIABLE: YES" "$readiness_status $(readiness_line "CERTIFIABLE:")"
expect_contains "time limits: the timeout is the reason" "the full gate timed out" "$(readiness_line "READY:")"
expect_equal "time limits: nothing is left in the temporary directory" "" "$(ls -A "$readiness_root/timeout-tmp")"
build_readiness_project review-timeout '"sleep 30"' 0
READINESS_REVIEW_TIMEOUT_SECONDS=2 run_readiness
expect_contains "time limits: a reviewer past its limit is an error" "EXTERNAL REVIEW: ERROR (timed out after 2 s; stopped, exit" "$(readiness_line "EXTERNAL REVIEW:")"
expect_contains "time limits: a reviewer timeout is READY NO at tier 0" "the configured external review did not pass (ERROR (timed out" "$(readiness_line "READY:")"
READINESS_TOTAL_TIMEOUT_SECONDS=1 run_readiness
expect_not_certifiable "time limits: the overall limit" "the readiness time limit of 1 s was reached before the external review"
# A handled TERM stops the running gate's process group and removes every temporary root.
build_readiness_project terminated null 0 "sh '$readiness_root/slow-gate.sh'"
printf '#!/bin/sh\n: >"%s"\nsleep 30\n: >"%s"\n' "$readiness_root/slow-gate-started" "$readiness_root/slow-gate-finished" >"$readiness_root/slow-gate.sh"
mkdir -p "$readiness_root/terminate-tmp"
CLAUDE_CONFIG_DIR="$config_directory" TMPDIR="$readiness_root/terminate-tmp" "$installed_readiness" WORK-001 --inc I1 "$readiness_project" >"$readiness_root/terminated.out" 2>&1 &
terminated_pid=$!
for _ in $(seq 1 300); do [ -e "$readiness_root/slow-gate-started" ] && break; sleep 0.2; done
kill -TERM "$terminated_pid" 2>/dev/null
wait "$terminated_pid"
expect_equal "termination: exit 4" 4 "$?"
case "$(cat "$readiness_root/terminated.out")" in *"READY:"*) fail "termination: no READY verdict is printed" ;; *) pass ;; esac
sleep 1
expect_equal "termination: every temporary root is removed" "" "$(ls -A "$readiness_root/terminate-tmp")"
if [ -e "$readiness_root/slow-gate-finished" ]; then fail "termination: the gate kept running"; else pass; fi
# Already NOT CERTIFIABLE: neither the external review nor the gate runs.
build_readiness_project skip-not-certifiable '"true"' 0 "sh '$readiness_root/marker-gate.sh'"
printf '#!/bin/sh\n: >"%s"\n' "$readiness_root/marker-gate-ran" >"$readiness_root/marker-gate.sh"
printf 'untracked\n' >"$readiness_project/notes.txt"
run_readiness
expect_not_certifiable "skipping: an uncertifiable run" "uncommitted changes in the working tree (notes.txt)"
expect_equal "skipping: the gate is not run" "GATE full: NOT RUN (not certifiable)" "$(readiness_line "GATE full:")"
expect_equal "skipping: the external review is not run" "EXTERNAL REVIEW: NOT RUN (not certifiable) (required at tier 2)" "$(readiness_line "EXTERNAL REVIEW:")"
if [ -e "$readiness_root/marker-gate-ran" ]; then fail "skipping: the gate command ran"; else pass; fi
rm "$readiness_project/notes.txt"
run_readiness
expect_ready_yes "skipping: control, a certifiable run"
if [ -e "$readiness_root/marker-gate-ran" ]; then pass; else fail "skipping: control, the gate command ran"; fi

# --- more negative cells: base, increment record, item status, evidence, environment
build_readiness_project more-negatives null 0
cp "$(readiness_state_file)" "$readiness_root/more-negatives-state.json"
restore_more_negatives() { cp "$readiness_root/more-negatives-state.json" "$(readiness_state_file)"; }
orphan_commit="$(readiness_git "$readiness_project" commit-tree -m orphan "$readiness_base^{tree}")"
readiness_git "$readiness_project" update-ref refs/remotes/origin/main "$orphan_commit"
edit_readiness_state ".increments[0].baseSha = \"$orphan_commit\""
run_readiness
expect_not_certifiable "base: a recorded base that is not an ancestor of HEAD" "is not an ancestor of HEAD"
readiness_git "$readiness_project" update-ref refs/remotes/origin/main "$readiness_base"
restore_more_negatives
edit_readiness_state '.increments[0].baseSha = "0000000000000000000000000000000000000001"'
run_readiness
expect_not_certifiable "base: a recorded base that is not a commit" "is not a commit in this repository"
restore_more_negatives
readiness_git "$readiness_project" update-ref -d refs/remotes/origin/main
run_readiness
expect_not_certifiable "base: the default-branch ref deleted" "the default-branch ref changed after the increment began"
readiness_git "$readiness_project" update-ref refs/remotes/origin/main "$readiness_base"
edit_readiness_state '.increments[0].status = "planned"'
run_readiness
expect_not_certifiable "increment: not active or ready" "increment I1 is planned, not active or ready"
restore_more_negatives
edit_readiness_state ".increments[0].headSha = \"$orphan_commit\""
run_readiness
expect_not_certifiable "increment: a recorded head that is not an ancestor of HEAD" "the recorded head $orphan_commit is not an ancestor of HEAD"
restore_more_negatives
edit_readiness_state '.increments[0].worktreeBranches = ["work/WORK-001-I1"]'
run_readiness
expect_not_certifiable "increment: a branch recorded twice" "a branch is recorded more than once in the work item"
restore_more_negatives
edit_readiness_state '.increments[0].activeAt = null'
run_readiness
expect_not_certifiable "increment: no activeAt" "increment I1 has no recorded activeAt time"
restore_more_negatives
edit_readiness_state '.increments[0].tier = 2'
run_readiness
expect_equal "state tier 2 alone is a classified tier 2" "1 EFFECTIVE TIER: 2 (classified)" "$readiness_status $(readiness_line "EFFECTIVE TIER:")"
restore_more_negatives
ws_ready evidence WORK-001 --inc I1 --kind review --reviewer qa --result pass --sha "$orphan_commit" >/dev/null
run_readiness
expect_equal "evidence: a commit that is not an ancestor of HEAD is stale" "QA (internal): STALE" "$(readiness_line "QA (internal):")"
record_review qa
ws_ready pause WORK-001 >/dev/null
run_readiness
expect_equal "item: a paused item is READY NO, certifiable" "1 CERTIFIABLE: YES" "$readiness_status $(readiness_line "CERTIFIABLE:")"
expect_contains "item: the status is the reason" "the work item is paused, not delivering" "$(readiness_line "READY:")"
ws_ready deliver WORK-001 --owner-command deliver >/dev/null
printf 'x\n' >"$readiness_project/.git/info/attributes"
run_readiness
expect_not_certifiable "classifier: an error is NOT CERTIFIABLE" "the classifier failed"
rm "$readiness_project/.git/info/attributes"
run_readiness
expect_ready_yes "more negatives: restored"
mkdir -p "$readiness_root/not-a-repository"
readiness_output="$(CLAUDE_CONFIG_DIR="$config_directory" "$installed_readiness" WORK-001 --inc I1 "$readiness_root/not-a-repository" 2>/dev/null)"
expect_equal "environment: not a Git repository is exit 2" 2 "$?"
expect_equal "environment: no block is printed" "" "$readiness_output"

# ---------------------------------------------------------------- inject-standards
output="$(CLAUDE_PLUGIN_ROOT="$repository_directory/plugins/ai-engineering" "$scripts/inject-standards.sh")"
expect_contains "inject-standards: includes standards body" "# Engineering Standards" "$output"
case "$output" in *"user-invocable"*) fail "inject-standards: frontmatter leaked into context" ;; *) pass ;; esac

echo "tests: $passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
