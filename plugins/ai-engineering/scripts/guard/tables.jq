# Guard v2 classification tables. Declarative data: adding a program or verb is a change
# here plus a case in tests/run.sh. classify.jq interprets these tables.

# Class labels are stable identifiers. The deploy classes are consumed by delivery policy
# (WORK-002); everything classified here asks the human, or denies when bundled.
#   infrastructure-apply  kubernetes-delete  cloud-destructive  destructive-sql
#   git-force-push  git-main-push  git-tag-push  pr-merge  release-create
#   package-publish  image-publish  platform-destructive  destructive-task
#   production-deploy  ephemeral-deploy  unclassified-deploy

# Rules matched against a program name and its non-flag arguments.
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
  {p: ["gh"], seq: [["pr"], ["merge"]], c: ["pr-merge"]},
  {p: ["glab"], seq: [["mr"], ["merge"]], c: ["pr-merge"]},
  {p: ["gh", "glab"], seq: [["release"], ["create", "delete", "edit"]], c: ["release-create"]},
  {p: ["npm", "pnpm", "yarn", "bun"], any: ["publish"], c: ["package-publish"]},
  {p: ["cargo", "poetry", "flit", "hatch"], any: ["publish"], c: ["package-publish"]},
  {p: ["twine"], any: ["upload"], c: ["package-publish"]},
  {p: ["gem", "nuget"], any: ["push"], c: ["package-publish"]},
  {p: ["docker", "podman"], any: ["push"], c: ["image-publish"]},
  {p: ["neon", "neonctl"],
   seq: [["branches", "branch", "projects", "project", "databases", "database", "roles", "role"], ["delete", "rm"]],
   c: ["platform-destructive"]},
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
  "env": {vf: ["-u", "-S", "-C", "--unset", "--chdir", "--split-string"], assign: true},
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
  "op": {sub: ["run"], dashdash: true}
};

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
        (if $method == "POST" and ($clean | test("(^|/)(deployments|deploys)(/|$)")) then "unclassified-deploy" else empty end) ]
  end;

# ssh options that take a value (the first other word is the host).
def ssh_value_flags: ["-p", "-i", "-o", "-l", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-e", "-E", "-I", "-m", "-O", "-Q", "-S", "-w", "-W", "-B"];
# git options placed before the subcommand that take a separate value.
def git_value_flags: ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"];
