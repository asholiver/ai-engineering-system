# Guard v2 classification tables. Declarative data: adding a program or verb is a change
# here plus a case in tests/run.sh. classify.jq interprets these tables.

# Class labels are stable identifiers. The deploy classes are consumed by delivery policy
# (WORK-002); everything classified here asks the human, or denies when bundled.
#   infrastructure-apply  kubernetes-delete  cloud-destructive  destructive-sql
#   git-force-push  git-main-push  git-tag-push  pr-merge  release-create
#   package-publish  image-publish  platform-destructive  destructive-task
#   production-deploy  ephemeral-deploy  unclassified-deploy

# Flags that take a separate value, per CLI, so a value is not mistaken for a verb
# (`gh pr -R o/r merge`).
def gh_value_flags: ["-R", "--repo", "--hostname", "-H", "--header", "-B", "--base"];
def neon_value_flags: ["--project-id", "--org-id", "--context-file", "--api-key", "--output", "-o", "--branch", "--name", "--parent"];

# Rules matched against a program name and its non-flag arguments.
#   always matches whatever the arguments are (the program itself is the operation)
#   vf  flags whose next word is a value and is skipped when matching seq
#   p    programs this rule applies to
#   any  matches when any non-flag argument equals one of these verbs
#   seq  matches when non-flag arguments contain these words consecutively
#        (each position lists its alternatives)
#   re   matches when any non-flag argument matches this regular expression
#   with extra arguments (flags included) that must also be present
#   c    classes the operation carries
def rules: [
  {p: ["terraform", "tofu", "terragrunt"], any: ["apply", "destroy"], c: ["infrastructure-apply"]},
  {p: ["pulumi"], any: ["up", "destroy"], c: ["infrastructure-apply"]},
  {p: ["cdk", "cdktf", "aws-cdk"], any: ["destroy"], c: ["infrastructure-apply"]},
  {p: ["cdk", "cdktf", "aws-cdk"], any: ["deploy"], c: ["infrastructure-apply", "unclassified-deploy"]},
  {p: ["serverless", "sls", "sam"], any: ["remove", "delete"], c: ["infrastructure-apply"]},
  {p: ["serverless", "sls", "sam"], any: ["deploy"], c: ["infrastructure-apply", "unclassified-deploy"]},
  {p: ["kubectl", "oc"], any: ["delete", "drain"], c: ["kubernetes-delete"]},
  {p: ["helm"], any: ["uninstall", "delete"], c: ["kubernetes-delete"]},
  {p: ["aws", "gcloud", "az", "gsutil"],
   re: "^(rm|rb|[a-z0-9-]*(delete|terminate|destroy|purge|remove|deregister)[a-z0-9-]*)$", c: ["cloud-destructive"]},
  {p: ["aws"], any: ["sync"], with: ["--delete"], c: ["cloud-destructive"]},
  {p: ["gh"], seq: [["pr"], ["merge"]], vf: gh_value_flags, c: ["pr-merge"]},
  {p: ["glab"], seq: [["mr"], ["merge"]], vf: gh_value_flags, c: ["pr-merge"]},
  {p: ["gh", "glab"], seq: [["release"], ["create", "delete", "edit", "upload"]], vf: gh_value_flags, c: ["release-create"]},
  {p: ["gh"], seq: [["repo"], ["delete"]], vf: gh_value_flags, c: ["platform-destructive"]},
  {p: ["dropdb"], always: true, c: ["destructive-sql"]},
  {p: ["mysqladmin"], any: ["drop"], c: ["destructive-sql"]},
  {p: ["prisma"], seq: [["migrate"], ["reset"]], c: ["destructive-sql"]},
  {p: ["prisma"], seq: [["db"], ["push"]], with: ["--force-reset"], c: ["destructive-sql"]},
  {p: ["neon", "neonctl"], seq: [["branches", "branch"], ["reset", "restore"]], vf: neon_value_flags, c: ["platform-destructive"]},
  {p: ["netlify", "ntl"], any: ["env:unset"], c: ["platform-destructive"]},
  {p: ["vercel", "vc"], seq: [["env"], ["add", "rm", "remove"]], vf: ["--token", "-t", "--scope", "-S", "--cwd", "-A"], c: ["platform-destructive"]},
  {p: ["npm", "pnpm", "yarn", "bun"], any: ["publish"], c: ["package-publish"]},
  {p: ["cargo", "poetry", "flit", "hatch"], any: ["publish"], c: ["package-publish"]},
  {p: ["twine"], any: ["upload"], c: ["package-publish"]},
  {p: ["gem", "nuget"], any: ["push"], c: ["package-publish"]},
  {p: ["docker", "podman"], any: ["push"], c: ["image-publish"]},
  {p: ["neon", "neonctl"],
   seq: [["branches", "branch", "projects", "project", "databases", "database", "roles", "role"], ["delete", "rm"]],
   vf: neon_value_flags, c: ["platform-destructive"]},
  {p: ["vercel", "vc"], any: ["remove", "rm"], c: ["platform-destructive"]},
  {p: ["netlify", "ntl"], any: ["sites:delete"], c: ["platform-destructive"]}
];

# Programs that read SQL (or database shell commands) from arguments and standard input.
def sql_clients: ["psql", "mysql", "mariadb", "sqlite3", "mongosh", "sqlcmd", "clickhouse-client", "pgcli", "mycli", "usql"];
# Programs whose inline code or standard input is scanned for destructive SQL only.
def interpreters_regex: "^(python[0-9.]*|pypy3?|node|nodejs|deno|bun|ruby|perl|php|lua|Rscript|tsx|ts-node)$";
# Programs that execute text as shell commands.
def shells: ["bash", "sh", "zsh", "dash", "ksh", "ash"];

# Destructive SQL. The interpreter variant is stricter so prose such as "truncate the
# string" in inline code does not match (documented residual category).
def sql_destructive_regex:
  "\\b(drop\\s+(table|database|schema|view|index|user|role|function|procedure|materialized\\s+view|extension)\\b|truncate\\b)";
def interpreter_sql_destructive_regex:
  "\\b(drop\\s+(table|database|schema|view|index|user|role|function|procedure|materialized\\s+view|extension)\\b|truncate\\s+table\\b|truncate\\s+[a-z_][a-z0-9_.]*\\s*([;`'\")]|$|\\s+(restart|cascade|continue)\\b))";
def mongo_destructive_regex: "\\b(dropDatabase\\s*\\(|\\.drop\\s*\\()";

# Wrappers: programs that run another command. After the optional subcommand (sub) and
# flags (vf lists flags that take a separate value), the next word is the wrapped program.
#   assign   skip NAME=value words     skip  positionals to skip (timeout DURATION)
#   lookup   flags that make it a lookup, not an execution (command -v)
#   dashdash the wrapped program follows --
def wrappers: {
  "sudo": {vf: ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t", "--user", "--group", "--host", "--prompt", "--chdir"], assign: true},
  "doas": {vf: ["-u", "-C"]},
  "env": {vf: ["-u", "-S", "-C", "--unset", "--chdir", "--split-string"], assign: true, tf: ["-S", "--split-string"]},
  "time": {vf: ["-f", "-o", "--format", "--output"]},
  "nice": {vf: ["-n", "--adjustment"]},
  "ionice": {vf: ["-c", "-n", "-p", "-P", "-u"]},
  "nohup": {},
  "setsid": {},
  "exec": {vf: ["-a"]},
  "builtin": {},
  "command": {lookup: ["-v", "-V"]},
  "stdbuf": {vf: ["-i", "-o", "-e"]},
  "timeout": {vf: ["-s", "-k", "--signal", "--kill-after"], skip: 1},
  "xargs": {vf: ["-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a", "-J", "-R", "-S", "--replace", "--max-args", "--max-procs", "--max-lines", "--delimiter", "--eof", "--arg-file", "--max-chars"]},
  "npx": {vf: ["-p", "--package", "--cache", "--userconfig", "--registry"]},
  "bunx": {},
  "uvx": {vf: ["--from", "--with", "-p", "--python", "--index-url"]},
  "pnpm": {sub: ["exec", "dlx"], vf: ["-C", "--dir", "--filter", "-F"]},
  "yarn": {sub: ["dlx", "exec"], vf: ["--cwd"]},
  "npm": {sub: ["exec", "x"], vf: ["--prefix", "-w", "--workspace"]},
  "bun": {sub: ["x"]},
  "uv": {sub: ["run"]},
  "poetry": {sub: ["run"]},
  "doppler": {sub: ["run"], dashdash: true},
  "aws-vault": {sub: ["exec"], dashdash: true},
  "op": {sub: ["run"], dashdash: true},
  "caffeinate": {vf: ["-t", "-w"]},
  "chronic": {},
  "unbuffer": {},
  "chrt": {skip: 1},
  "taskset": {vf: ["-c", "--cpu-list"], skip: 1},
  "flock": {vf: ["-w", "--timeout", "-E", "--conflict-exit-code"], skip: 1, tf: ["-c", "--command"]},
  "script": {vf: ["-t", "-F", "-T", "-c", "--command"], skip: 1, tf: ["-c", "--command"]},
  "su": {vf: ["-s", "-g", "-G", "-c", "--shell", "--group", "--command"], tf: ["-c", "--command"], noexec: true},
  "nix-shell": {vf: ["-p", "--packages", "-I", "--run", "--command"], tf: ["--run", "--command"], noexec: true},
  "watch": {vf: ["-n", "--interval"], joined: true},
  "parallel": {vf: ["-j", "-n", "-N", "-a", "-S", "--jobs", "--max-args", "--arg-file", "--sshlogin", "-L"], parallel: true},
  "coproc": {coproc: true},
  "docker": {sub: ["exec", "run"], vf: ["-H", "--host", "--context", "-c", "-l", "--log-level", "-e", "--env", "-u", "--user", "-w", "--workdir", "--env-file", "--detach-keys", "--name", "--network", "--entrypoint", "-v", "--volume", "-p", "--publish", "--platform"], subskip: 1},
  "podman": {sub: ["exec", "run"], vf: ["-e", "--env", "-u", "--user", "-w", "--workdir", "--env-file", "--detach-keys", "--name", "--network", "--entrypoint", "-v", "--volume", "-p", "--publish"], subskip: 1},
  "docker-compose": {sub: ["exec", "run"], vf: ["-e", "--env", "-u", "--user", "-w", "--workdir", "-f", "--file", "-p", "--project-name", "--index", "--profile", "-v", "--volume", "--name", "--entrypoint"], subskip: 1},
  "kubectl": {sub: ["exec", "run", "debug"], sub_dashdash: ["run", "debug"], vf: ["-n", "--namespace", "-c", "--container", "--context", "--kubeconfig", "-f", "--filename", "-s", "--server", "--cluster", "--user", "--as", "--request-timeout", "-l", "--selector", "--image", "--target", "--profile", "--copy-to", "--env", "--overrides", "--port", "--labels", "--restart"], dashdash_optional: true, subskip: 1},
  "oc": {sub: ["exec", "run", "debug"], sub_dashdash: ["run", "debug"], vf: ["-n", "--namespace", "-c", "--container", "--context", "--kubeconfig", "-f", "--filename", "-s", "--server", "--image"], dashdash_optional: true, subskip: 1}
};
# Wrapper options that change the working directory of the wrapped command (path resolution).
def wrapper_chdir_flags: {"env": ["-C", "--chdir"], "sudo": ["-D", "--chdir"]};

# Programs that run a binary from the package's own bin when the word is not a built-in
# command (pnpm and yarn): `pnpm vercel --prod` runs vercel.
def binary_runners: ["pnpm", "yarn"];
def runner_builtins: ["add", "install", "i", "remove", "rm", "uninstall", "update", "up", "upgrade", "run", "test", "t", "start", "stop", "restart", "exec", "dlx", "create", "init", "pack", "link", "unlink", "list", "ls", "outdated", "audit", "why", "store", "config", "root", "bin", "prune", "rebuild", "patch", "fetch", "import", "env", "setup", "licenses", "doctor", "cache", "help", "version", "info", "workspace", "workspaces", "global", "set", "node", "dedupe", "login", "logout", "whoami", "publish", "deploy", "release", "tag", "npm", "constraints", "plugin", "up-to-date", "self-update", "approve-builds", "catalog"];

# Package names that run a binary with a different name.
def program_aliases: {"netlify-cli": "netlify", "vercel-cli": "vercel", "neon-cli": "neonctl"};

# Commands that only set up the environment. A reserved operation preceded only by these
# still asks instead of denying.
def context_programs: ["cd", "pushd", "popd", "export", "set", "unset", "declare", "typeset", "readonly", "local", "[", "[[", "test", "true", "false", ":"];
def activation_script_regex: "(^|/)(activate|nvm\\.sh|env|\\.env)$";

# Task runners: any non-flag argument naming deploy, release or publish work.
def task_runners_packages: ["npm", "pnpm", "yarn", "bun"];
def task_runners_other: ["make", "just", "task", "mage"];
def package_non_task_subcommands: ["install", "i", "add", "remove", "rm", "uninstall", "update", "up", "upgrade", "ci", "audit", "outdated", "ls", "list", "view", "info", "search", "why", "link", "unlink", "prune", "dedupe", "pack", "init", "config", "cache", "help", "version", "whoami", "login", "logout", "bin", "root", "prefix"];
def deploy_word_regex: "deploy|release|publish";
def destroy_word_regex: "destroy|teardown";
# Programs whose first script argument is run as a script (path with a deploy-like name).
def script_runners: ["bash", "sh", "zsh", "dash", "ksh", "ash", "node", "nodejs", "python", "python3", "ruby", "perl", "tsx", "ts-node", "deno", "bun", "source", "."];

# Platform CLIs with deploy semantics.
def vercel_non_deploy_subcommands: ["list", "ls", "inspect", "logs", "env", "domains", "dns", "certs", "secrets", "alias", "project", "projects", "link", "pull", "dev", "build", "login", "logout", "whoami", "teams", "switch", "git", "help", "bisect", "cache", "webhooks", "integration", "install", "init", "open", "curl", "httpstat", "rm", "remove"];
def vercel_value_flags: ["--token", "-t", "--scope", "-S", "--cwd", "-A", "--local-config", "--global-config", "-e", "--env", "-b", "--build-env", "-m", "--meta", "--regions", "--target", "--archive", "--name", "-n"];
def netlify_value_flags: ["--site", "-s", "--dir", "-d", "--functions", "-f", "--message", "-m", "--alias", "--auth", "--filter", "--build-hooks"];

# HTTP clients: flags that take a value, and how a request becomes a write.
def curl_value_letters: "XdFHoumeAbcwTxEKPrtzCYyQDU";
def curl_value_long: ["--request", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode", "--form", "--form-string", "--json", "--upload-file", "--header", "--output", "--user", "--user-agent", "--referer", "--cookie", "--cookie-jar", "--connect-timeout", "--max-time", "--retry", "--write-out", "--proxy", "--cacert", "--cert", "--key", "--url", "--config", "--resolve", "--range", "--time-cond", "--proxy-user", "--limit-rate"];
def curl_body_long: ["--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode", "--form", "--form-string", "--json"];
def wget_value_flags: ["-O", "-o", "-P", "-e", "-U", "-i", "-t", "-T", "-w", "-Q", "--output-document", "--output-file", "--directory-prefix", "--header", "--user", "--password", "--user-agent", "--input-file", "--tries", "--timeout", "--wait", "--quota", "--method", "--post-data", "--post-file", "--body-data", "--body-file"];
def gh_api_value_flags: ["-X", "--method", "-H", "--header", "-f", "--raw-field", "-F", "--field", "--input", "-q", "--jq", "-t", "--template", "--hostname", "--cache", "-p", "--preview"];
def gh_api_body_flags: ["-f", "--raw-field", "-F", "--field", "--input"];
def http_methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"];
def httpie_value_flags: ["--auth", "-a", "--auth-type", "-A", "--print", "-p", "--pretty", "--style", "-s", "--timeout", "--proxy", "--verify", "--cert", "--cert-key", "--session", "--session-read-only", "--output", "-o", "--max-redirects", "--default-scheme", "--ssl", "--ciphers"];

# Endpoints of recognised write operations (matched against the URL path, write methods only).
def endpoint_classes($method; $path):
  if ($method | IN("POST", "PUT", "PATCH", "DELETE")) | not then []
  else
    ($path | sub("[?#].*$"; "") | sub("/+$"; "") | ascii_downcase) as $clean
    | [ (if ($clean | test("(^|/)releases(/|$)")) then "release-create" else empty end),
        (if ($clean | test("(^|/)(pulls|merge_requests)/[0-9]+/merge$|(^|/)merges$")) then "pr-merge" else empty end),
        (if $method == "DELETE" and ($clean | test("(^|/)git/refs(/|$)")) then "git-force-push" else empty end),
        # Moving or creating a ref through the API is a push: main and master are the protected ones.
        (if ($method | IN("PATCH", "POST")) and ($clean | test("(^|/)git/refs(/|$)"))
         then (if ($clean | test("(^|/)git/refs/(heads/)?(main|master)$")) then "git-main-push" else "git-force-push" end) else empty end),
        (if $method == "POST" and ($clean | test("(^|/)(deployments|deploys)(/|$)")) then "unclassified-deploy" else empty end) ]
  end;

# ssh options that take a value (the first other word is the host).
def ssh_value_flags: ["-p", "-i", "-o", "-l", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-e", "-E", "-I", "-m", "-O", "-Q", "-S", "-w", "-W", "-B"];
# git options placed before the subcommand that take a separate value.
def git_value_flags: ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env", "--exec-path", "--list-cmds"];
# Git commands (built in, plumbing and common extensions). A word that is none of these is an
# alias or an external command, which the parser cannot see through.
def git_commands: ["add", "am", "annotate", "apply", "archive", "bisect", "blame", "branch", "bundle", "cat-file", "check-attr", "check-ignore", "check-ref-format", "checkout", "checkout-index", "cherry", "cherry-pick", "citool", "clean", "clone", "column", "commit", "commit-graph", "commit-tree", "config", "count-objects", "credential", "daemon", "describe", "diff", "diff-files", "diff-index", "diff-tree", "difftool", "fast-export", "fast-import", "fetch", "filter-branch", "flow", "fmt-merge-msg", "for-each-ref", "format-patch", "fsck", "gc", "get-tar-commit-id", "grep", "gui", "hash-object", "help", "init", "instaweb", "interpret-trailers", "lfs", "log", "ls-files", "ls-remote", "ls-tree", "mailinfo", "mailsplit", "maintenance", "merge", "merge-base", "mergetool", "mktag", "mktree", "mv", "name-rev", "notes", "pack-objects", "pack-refs", "patch-id", "prune", "pull", "push", "range-diff", "read-tree", "rebase", "reflog", "remote", "repack", "replace", "request-pull", "rerere", "reset", "restore", "rev-list", "rev-parse", "revert", "rm", "send-email", "shortlog", "show", "show-branch", "show-ref", "sparse-checkout", "stage", "stash", "status", "stripspace", "submodule", "subtree", "switch", "symbolic-ref", "tag", "update-index", "update-ref", "var", "verify-commit", "verify-pack", "verify-tag", "version", "whatchanged", "worktree",
                      "write-tree", "merge-tree", "merge-file", "unpack-objects", "index-pack", "show-index", "update-server-info"];

# ---------------------------------------------------------------- proven data (the only floor exemptions)
# The keyword floor reads the whole command except these spans, which are proven to be data.
# classify.jq (proven_data) applies them; each one has a test in tests/run.sh. Keep this narrow.
# Search tools: their patterns and paths are data unless an option makes them run a program.
def search_programs: ["grep", "egrep", "fgrep", "rg", "ag"];
# (classify.jq tests these as prefixes: --pre, --hostname-bin, --pager.)
# Programs whose output stays data when they are the only readers of an echo, printf or cat:
# they cannot run what they read. Shells, SQL clients, xargs and interpreters read it too, but
# their input is parsed, scanned or (interpreters) a documented residual; anything else is not data.
def data_sinks: ["cat", "tee", "grep", "egrep", "fgrep", "rg", "ag", "head", "tail", "wc", "sort", "uniq", "cut", "tr", "jq", "yq",
                 "less", "more", "pbcopy", "base64", "xxd", "shasum", "sha256sum", "md5", "md5sum", "diff", "cmp", "column", "fold",
                 "nl", "od", "hexdump", "strings", "fmt", "rev", "paste", "comm", "iconv"];
# NR-3b: options that make a data sink run a program. A sink given one of these is not a sink.
# Audit of every other entry (none can run what it reads or a program named in its arguments):
#   cat, tee, head, tail, wc, uniq, cut, tr, fold, nl, od, hexdump, strings, fmt, rev, paste, comm,
#   column, iconv, base64, xxd, shasum, sha256sum, md5, md5sum, cmp: read, transform or write data
#   only (tee writes files: its targets are judged by the store and tree policies; a process
#   substitution target is handled separately);
#   grep, egrep, fgrep: no option runs a program (GNU and BSD; BSD -Z decompresses in-process);
#   diff: --paginate runs the fixed program pr, never one named on the command line;
#   jq, yq: no function runs a program; pbcopy: clipboard only.
# Executing options: sort --compress-program, rg --pre and --hostname-bin, ag --pager, and less or
# more with an initial command (+cmd, which can be a shell escape) or a lesskey file.
def data_sink_exec_regex: {
  "sort": "^--compress-program",
  "rg": "^--(pre|hostname-bin)",
  "ag": "^--pager",
  "less": "^(\\+|-[A-Za-z]*k|--lesskey)",
  "more": "^(\\+|-[A-Za-z]*k|--lesskey)"
};
# A sed script made only of s commands with no e (execute) or w (write file) flag is data.
#   one command: optional line address, s, a delimiter, two parts, flags; separated by ; or newline.
#   Whitespace around commands is ASCII space, tab or newline only (NR-1: sed does not skip Unicode spaces).
def sed_substitutions_regex:
  "^(?:[ \\t\\n]*(?:[0-9]+|\\$)?(?:,(?:[0-9]+|\\$))?[ \\t]*s(?<d>[^\\\\\\n\\s])(?:\\\\[\\s\\S]|(?!\\k<d>)[^\\n])*\\k<d>(?:\\\\[\\s\\S]|(?!\\k<d>)[^\\n])*\\k<d>[gpiImM0-9]*[ \\t]*(?:[;\\n]|$))+$";
# Git subcommands whose non-flag operands are paths or revisions (data), and the ones whose
# message values (-m/-F/--message/--file) are data.
def git_operand_data_subcommands: ["add", "rm", "mv", "diff", "show", "blame", "ls-files", "status", "log", "grep", "restore"];
def git_message_subcommands: ["commit", "tag", "notes"];
# gh release subcommands that only read.
def gh_release_read_subcommands: ["download", "view", "list"];

# ---------------------------------------------------------------- executing constructs
# An inert-looking program with one of these is never data, and the shell text it runs is parsed.
# Git: -c keys a restricted agent may set (everything else is denied to it), options and
# subcommands that run a program, and configuration keys whose value is a command.
def git_safe_config_key_regex: "^(color\\..*|core\\.quotepath)$";
def git_exec_flag_regex: "^(--upload-pack|--receive-pack|--exec|--extcmd|--ext-diff|--textconv|--tool|--[A-Za-z-]+-filter)(=|$)";
# git grep only: open the matching files in a pager (a program).
def git_grep_pager_regex: "^(-O|--open-files-in-pager)";
def git_exec_subcommands: ["filter-branch", "filter-repo", "difftool", "mergetool"];
def git_command_config_regex:
  "^(core\\.(pager|editor|sshcommand|fsmonitor|askpass|gitproxy)|sequence\\.editor|pager\\..*|diff\\.external|gpg\\.(.*\\.)?program|gpg\\.ssh\\.defaultkeycommand|uploadpack\\.packobjectshook|merge\\..*\\.driver|filter\\..*\\.(clean|smudge|process)|diff\\..*\\.(textconv|command)|credential\\..*helper|alias\\..*)$";
# Options of other programs that run a command given as their value.
def exec_value_flags: {
  "tar": ["--to-command", "--use-compress-program", "-I", "--info-script", "--new-volume-script", "-F"],
  "gtar": ["--to-command", "--use-compress-program", "-I", "--info-script", "--new-volume-script", "-F"],
  "zip": ["-TT", "--unzip-command"],
  "sort": ["--compress-program"],
  "gsort": ["--compress-program"],
  "make": ["--eval", "-E"],
  "gmake": ["--eval", "-E"],
  "rg": ["--pre", "--hostname-bin"],
  "ag": ["--pager"]
};
def awk_programs: ["awk", "gawk", "mawk", "nawk"];
# N6(b): options of patch, git apply and git am that take a separate value (so a value is not
# taken for a patch file).
def patch_value_flags: ["-p", "-d", "-i", "-o", "-r", "-B", "-V", "-z", "-D", "-F", "-Y", "-g", "--input", "--output", "--directory",
                        "--reject-file", "--strip", "--prefix", "--suffix", "--basename-prefix", "--fuzz", "--ifdef", "--version-control",
                        "--quoting-style", "--get"];
def git_patch_value_flags: ["-p", "-C", "--directory", "--include", "--exclude", "--whitespace", "--build-fake-ancestor", "--patch-format",
                            "--resolvemsg", "--exec"];
# H5: environment variables a restricted agent may set for Git (name, and the value when one is
# required). Everything else is denied: GIT_EXTERNAL_DIFF, GIT_PAGER and PAGER (other values),
# GIT_EDITOR, EDITOR, VISUAL, GIT_SSH, GIT_SSH_COMMAND, GIT_ASKPASS, SSH_ASKPASS, GIT_EXEC_PATH,
# GIT_CONFIG*, GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_TEMPLATE_DIR, GIT_PROXY_COMMAND, ...
def git_env_safe_names_regex: "^(LANG|LC_[A-Z_]+|TZ|NO_COLOR|TERM)$";
def git_env_safe_values: {"GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat", "PAGER": "cat"};
# Names whose export earlier in a submission changes what a later git runs (tracked across commands).
def git_env_tracked_regex: "^(GIT_[A-Z0-9_]*|PAGER|EDITOR|VISUAL|SSH_ASKPASS|LESSOPEN|LESSCLOSE|LESS|PATH|HOME|XDG_CONFIG_HOME|BASH_ENV|ENV)$";
# Input: an assignment word (NAME=value, or NAME alone for `export NAME`).
def git_env_safe:
  (sub("=.*$"; "")) as $name
  | (if contains("=") then sub("^[^=]*="; "") else null end) as $value
  | ($name | test(git_env_safe_names_regex)) or (git_env_safe_values[$name] != null and $value == git_env_safe_values[$name]);
# Kubernetes subcommands that only read (a pipeline producer that cannot change anything).
def kubernetes_read_subcommands: ["get", "describe", "logs", "top", "explain", "api-resources", "api-versions", "version", "cluster-info"];

# ---------------------------------------------------------------- keyword floor
# The v0.2 keyword rules, ported to jq. They run over the whole command text except the proven
# data spans above (see classify.jq floor_text), whatever the programs are: the result never
# drops below ask when one of them matches. Ask-only: a hit asks, never denies. [regex, class].
def kw_ws: "(^|[^A-Za-z0-9_-])";
def kw_we: "([^A-Za-z0-9_-]|$)";
def kw_gap: "([^A-Za-z0-9_-].*)?[^A-Za-z0-9_-]";
def kw_risky: "[^\\s]*(deploy|release|publish|destroy|teardown)[^\\s]*";
def keyword_net_rules: [
  [kw_ws + "(terraform|tofu|terragrunt)" + kw_gap + "(apply|destroy)" + kw_we, "infrastructure-apply"],
  [kw_ws + "pulumi" + kw_gap + "(up|destroy)" + kw_we, "infrastructure-apply"],
  [kw_ws + "(cdk|cdktf|aws-cdk)" + kw_gap + "(deploy|destroy)" + kw_we, "infrastructure-apply"],
  [kw_ws + "(serverless|sls|sam)" + kw_gap + "(deploy|remove|delete)" + kw_we, "infrastructure-apply"],
  [kw_ws + "(kubectl|oc)" + kw_gap + "(delete|drain)" + kw_we, "kubernetes-delete"],
  [kw_ws + "helm" + kw_gap + "(uninstall|delete)" + kw_we, "kubernetes-delete"],
  [kw_ws + "(aws|gcloud|az|gsutil)" + kw_gap + "(rm|rb|[a-z0-9-]*(delete|terminate|destroy|purge|remove|deregister)[a-z0-9-]*)" + kw_we, "cloud-destructive"],
  [kw_ws + "aws" + kw_gap + "sync" + kw_we + ".*--delete", "cloud-destructive"],
  [kw_ws + "drop\\s+(table|database|schema|view|index|user|role|function|procedure)" + kw_we, "destructive-sql"],
  [kw_ws + "truncate" + kw_we, "destructive-sql"],
  [kw_ws + "gh" + kw_gap + "pr\\s+merge" + kw_we, "pr-merge"],
  [kw_ws + "glab" + kw_gap + "mr\\s+merge" + kw_we, "pr-merge"],
  [kw_ws + "gh" + kw_gap + "api" + kw_we + ".*pulls/[0-9]+/merge", "pr-merge"],
  [kw_ws + "(gh|glab)" + kw_gap + "release\\s+(create|delete|edit|upload)" + kw_we, "release-create"],
  [kw_ws + "(npm|pnpm|yarn|bun)" + kw_gap + "publish" + kw_we, "package-publish"],
  [kw_ws + "(cargo|poetry|flit|hatch)" + kw_gap + "publish" + kw_we, "package-publish"],
  [kw_ws + "twine" + kw_gap + "upload" + kw_we, "package-publish"],
  [kw_ws + "(gem|nuget)" + kw_gap + "push" + kw_we, "package-publish"],
  [kw_ws + "(docker|podman)" + kw_gap + "push" + kw_we, "image-publish"],
  [kw_ws + "(neon|neonctl)" + kw_gap + "(branches?|projects?|databases?|roles?)" + kw_gap + "(delete|rm)" + kw_we, "platform-destructive"],
  [kw_ws + "(vercel|vc)" + kw_gap + "(remove|rm)" + kw_we, "platform-destructive"],
  [kw_ws + "(vercel|vc)" + kw_gap + "(promote|rollback)" + kw_we, "production-deploy"],
  [kw_ws + "(vercel|vc)" + kw_gap + "--prod(uction)?" + kw_we, "production-deploy"],
  [kw_ws + "(vercel|vc|netlify|ntl)" + kw_gap + "deploy" + kw_we, "unclassified-deploy"],
  [kw_ws + "(npm|pnpm|yarn|bun)" + kw_gap + kw_risky, "unclassified-deploy"],
  [kw_ws + "(make|just|task|mage)" + kw_gap + kw_risky, "unclassified-deploy"],
  ["(^|\\s)[^\\s]*/[^\\s/]*(deploy|release|publish|destroy|teardown)[^\\s/]*", "unclassified-deploy"]
];
# git push in the net: force, main/master and tag pushes, and any push while on main or master.
def keyword_net_push($text; $branch):
  if ($text | test(kw_ws + "git" + kw_gap + "push" + kw_we; "i")) | not then []
  else
    [ (if ($text | test("(^|\\s)(--force|--force-with-lease(=[^\\s]*)?|--mirror|--delete|-[A-Za-z]*[fd][A-Za-z]*)" + kw_we; "i")
           or ($text | test("(^|\\s)(\\+|:)[^\\s]+"))) then "git-force-push" else empty end),
      (if ($text | test("(^|\\s)([^\\s]*:)?(refs/heads/)?(main|master)" + kw_we; "i") or ($branch | IN("main", "master"))) then "git-main-push" else empty end),
      (if ($text | test("(^|\\s)(--tags|--follow-tags|[^\\s]*refs/tags/[^\\s]*)" + kw_we; "i")) then "git-tag-push" else empty end) ]
  end;
# Literal prefilter (compiling the rule regexes costs about 2.5 ms per call): every rule needs one
# of its program words and one of its verb words in the (lower-case) text. When no pair is
# present no rule can match, so the regexes are skipped; otherwise they decide.
def keyword_net_literals: [
  [["terraform", "tofu", "terragrunt"], ["apply", "destroy"]],
  [["pulumi"], ["up", "destroy"]],
  [["cdk"], ["deploy", "destroy"]],
  [["serverless", "sls", "sam"], ["deploy", "remove", "delete"]],
  [["kubectl", "oc"], ["delete", "drain"]],
  [["helm"], ["uninstall", "delete"]],
  [["aws", "gcloud", "az", "gsutil"], ["rm", "rb", "delete", "terminate", "destroy", "purge", "remove", "deregister", "sync"]],
  [["drop"], ["table", "database", "schema", "view", "index", "user", "role", "function", "procedure"]],
  [["truncate"], ["truncate"]],
  [["gh", "glab"], ["merge", "release"]],
  [["npm", "pnpm", "yarn", "bun", "cargo", "poetry", "flit", "hatch", "make", "just", "task", "mage"], ["publish", "deploy", "release", "destroy", "teardown"]],
  [["twine"], ["upload"]],
  [["gem", "nuget", "docker", "podman", "git"], ["push"]],
  [["neon"], ["delete", "rm"]],
  [["vercel", "vc", "netlify", "ntl"], ["remove", "rm", "promote", "rollback", "prod", "deploy"]],
  [["/"], ["deploy", "release", "publish", "destroy", "teardown"]]
];
def keyword_net_may_match: ascii_downcase as $lower
  | any(keyword_net_literals[]; any(.[0][]; . as $word | $lower | contains($word)) and any(.[1][]; . as $word | $lower | contains($word)));
# NR-1, NR-2: the texts the keyword rules read. Odd whitespace (CR, FF, VT, Unicode spaces) is a
# separator for them. When the text has non-ASCII characters it is read twice: with the APFS
# look-alikes folded (U+017F long s to s, U+212A Kelvin sign to k, the ff/fi/fl/ffi/ffl/st
# ligatures), and with every other non-ASCII character removed (an unknown character inside a
# word may be ignorable). Linear (explode/implode, no regex per character).
def odd_space_codepoint: IN(9, 10, 11, 12, 13, 133, 160, 5760, 6158, 8232, 8233, 8239, 8287, 8288, 12288, 65279) or (. >= 8192 and . <= 8205);
def keyword_fold_codepoint:
  if . < 128 then (if IN(11, 12, 13) then 32 else . end)
  elif odd_space_codepoint then 32
  elif . == 383 then 115
  elif . == 8490 then 107
  elif . == 64256 then (102, 102)
  elif . == 64257 then (102, 105)
  elif . == 64258 then (102, 108)
  elif . == 64259 then (102, 102, 105)
  elif . == 64260 then (102, 102, 108)
  elif . == 64261 or . == 64262 then (115, 116)
  else . end;
def keyword_text_variants:
  if test("[^\\x01-\\x7f]") then
    explode as $codes
    | [ ([ $codes[] | keyword_fold_codepoint ] | implode),
        ([ $codes[] | if odd_space_codepoint then 32 elif . < 128 then . else empty end ] | implode) ]
  elif test("[\r\f\u000b]") then [ gsub("[\r\f\u000b]"; " ") ]
  else [ . ] end;
def keyword_net($text; $branch):
  [ ($text | keyword_text_variants[]) as $variant
    | ($variant | gsub("[\\n\\t]"; " ")) as $flat
    | if ($flat | keyword_net_may_match) | not then empty
      else (keyword_net_rules[] | . as $rule | select($flat | test($rule[0]; "i")) | $rule[1]), keyword_net_push($flat; $branch)[] end ]
  | unique;
