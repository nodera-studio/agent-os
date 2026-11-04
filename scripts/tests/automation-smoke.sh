#!/bin/bash
# automation-smoke.sh — smoke test for the deterministic "script instead" scripts: run-ci.sh,
# dep-audit.sh, stale-reference-scan.sh, tech-debt-scan.sh, endpoint-inventory.sh,
# copywrite-checks.sh, blind-candidates.sh, close-run.sh, promote-preflight.sh, poll-pr.sh,
# seam-overlap.sh and mnemosyne/capture-findings.sh. (merge-trunk.sh is exercised by
# squash-merge-recipe-smoke.sh.)
#
# Usage: /bin/bash .claude/scripts/tests/automation-smoke.sh   (or harness-smoke.sh automation)
# Bash 3.2, no network, no real model. External commands (make, npm, gh) are stubs on PATH that
# log their calls and serve canned output; fixtures are throwaway git repos with the global and
# system git config ignored. Prints ok/FAIL per case and exits 1 on any FAIL. Needs jq.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SCRIPTS="$HERE/.."
TMP="$(mktemp -d "${TMPDIR:-/tmp}/automation-smoke.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tmp" && export TMPDIR="$TMP/tmp"
FAILS=0
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed"; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@example.invalid
export GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@example.invalid
unset GIT_DIR GIT_WORK_TREE GIT_NO_REPLACE_OBJECTS
export HARNESS_SCRATCH_PREFIX=autosmoke-

STUBS="$TMP/stubs"
mkdir -p "$STUBS"
export STUB_LOG="$TMP/stub.log"
: >"$STUB_LOG"
ORIG_PATH="$PATH"
PATH="$STUBS:$PATH"

ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
# eq <name> <got> <want>
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got [$2], want [$3]"; fi; }
# has <name> <haystack> <needle>
has() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1: [$3] not in [$2]" ;; esac; }
# lacks <name> <haystack> <needle>
lacks() { case "$2" in *"$3"*) fail "$1: [$3] found in [$2]" ;; *) ok "$1" ;; esac; }
# jqv <json> <filter>: the filter's raw output
jqv() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }
stublog_lines() { grep -c . "$STUB_LOG" 2>/dev/null || true; }

# newrepo <dir>: an empty git repo with one commit.
newrepo() {
  mkdir -p "$1"
  git init -q -b main "$1"
  : >"$1/.keep"
  git -C "$1" add -A && git -C "$1" commit -q -m init
}

# --- stubs: make and npm log "<tool> <args>" and obey STUB_FAIL / STUB_COMMIT ---
cat >"$STUBS/make" <<'EOF'
#!/bin/bash
echo "make $*" >>"$STUB_LOG"
[ -z "${STUB_COMMIT:-}" ] || git commit -q --allow-empty -m moved
if [ "$*" = "${STUB_FAIL:-}" ]; then echo "boom in $*"; exit 2; fi
echo "ran make $*"
EOF
cat >"$STUBS/npm" <<'EOF'
#!/bin/bash
echo "npm $*" >>"$STUB_LOG"
case "$1" in
  audit) cat "$STUB_NPM_DIR/audit.json"; exit 1 ;;
  outdated) cat "$STUB_NPM_DIR/outdated.json"; exit 1 ;;
  ci) exit "${STUB_NPM_CI_RC:-0}" ;;
  run) if [ "$*" = "${STUB_FAIL:-}" ]; then echo "boom in $*"; exit 1; fi; echo "ran npm $*" ;;
esac
EOF
cat >"$STUBS/pnpm" <<'EOF'
#!/bin/bash
echo "pnpm $*" >>"$STUB_LOG"
EOF
chmod +x "$STUBS/make" "$STUBS/npm" "$STUBS/pnpm"

# ===================================================================== run-ci.sh
suite_run_ci() {
  local R out rc

  R="$TMP/ci-make-all"; newrepo "$R"
  printf 'ci:\n\ttrue\nci-check:\n\ttrue\nci-build:\n\ttrue\nci-test:\n\ttrue\n' >"$R/Makefile"
  export HARNESS_SUITE_LOCK_DIR="$TMP/locks"
  : >"$STUB_LOG"
  out="$(bash "$SCRIPTS/run-ci.sh" --dir "$R")"; rc=$?
  eq "run-ci: make all exits 0" "$rc" 0
  eq "run-ci: make all uses the ci target" "$(jqv "$out" '[.steps[].command] | join(",")')" "make ci"
  eq "run-ci: make all status pass" "$(jqv "$out" .status)" pass
  eq "run-ci: the test-bearing step is locked" "$(jqv "$out" '.steps[0].locked')" true
  eq "run-ci: head is recorded" "$(jqv "$out" .head)" "$(git -C "$R" rev-parse HEAD)"

  printf 'ci-check:\n\ttrue\nci-build:\n\ttrue\nci-test:\n\ttrue\n' >"$R/Makefile"
  out="$(bash "$SCRIPTS/run-ci.sh" all --dir "$R")"
  eq "run-ci: no ci target falls back to the three" "$(jqv "$out" '[.steps[].name] | join(",")')" "ci-check,ci-build,ci-test"
  eq "run-ci: only the test target is locked" "$(jqv "$out" '[.steps[].locked | tostring] | join(",")')" "false,false,true"

  : >"$STUB_LOG"
  out="$(bash "$SCRIPTS/run-ci.sh" checks --dir "$R")"
  eq "run-ci: mode checks runs only ci-check" "$(cat "$STUB_LOG")" "make ci-check"

  out="$(STUB_FAIL="ci-build" bash "$SCRIPTS/run-ci.sh" --dir "$R")"; rc=$?
  eq "run-ci: a failing step exits 1" "$rc" 1
  eq "run-ci: failed_step is named" "$(jqv "$out" .failed_step)" ci-build
  eq "run-ci: later steps are skipped" "$(jqv "$out" '.steps[2].status')" skipped
  has "run-ci: the failure tail is carried" "$(jqv "$out" '.steps[1].tail')" "boom in ci-build"
  out="$(STUB_FAIL="ci-build" bash "$SCRIPTS/run-ci.sh" --keep-going --dir "$R")"
  eq "run-ci: --keep-going still runs the tests" "$(jqv "$out" '.steps[2].status')" pass

  out="$(bash "$SCRIPTS/run-ci.sh" --dry-run --dir "$R")"; rc=$?
  eq "run-ci: --dry-run plans without running" "$(jqv "$out" '.status + ":" + .steps[0].status')" "planned:planned"

  : >"$STUB_LOG"
  out="$(bash "$SCRIPTS/run-ci.sh" --expect-head deadbeef --dir "$R")"; rc=$?
  eq "run-ci: --expect-head mismatch exits 4" "$rc" 4
  eq "run-ci: --expect-head mismatch runs nothing" "$(stublog_lines)" 0
  out="$(bash "$SCRIPTS/run-ci.sh" --expect-head "$(git -C "$R" rev-parse --short HEAD)" --dir "$R")"; rc=$?
  eq "run-ci: an abbreviated matching head is accepted" "$rc" 0

  out="$(STUB_COMMIT=1 bash "$SCRIPTS/run-ci.sh" --dir "$R")"; rc=$?
  eq "run-ci: a head that moved mid-run is stale-head (exit 4)" "$rc:$(jqv "$out" .status)" "4:stale-head"

  R="$TMP/ci-npm"; newrepo "$R"
  printf '{"scripts":{"format:check":"p","lint":"l","typecheck":"t","build":"b","test":"x"}}\n' >"$R/package.json"
  : >"$STUB_LOG"
  out="$(bash "$SCRIPTS/run-ci.sh" --dir "$R")"; rc=$?
  eq "run-ci: npm project runs its scripts in order" "$(jqv "$out" '[.steps[].name] | join(",")')" "format,lint,typecheck,build,test"
  eq "run-ci: npm stack detected" "$(jqv "$out" .stack)" npm
  eq "run-ci: npm tests run under the lock" "$(jqv "$out" '.steps[4].locked')" true
  touch "$R/pnpm-lock.yaml"
  : >"$STUB_LOG"
  bash "$SCRIPTS/run-ci.sh" build --dir "$R" >/dev/null
  eq "run-ci: a pnpm lockfile selects pnpm" "$(cat "$STUB_LOG")" "pnpm run build"

  R="$TMP/ci-cargo"; newrepo "$R"
  printf '[package]\nname = "x"\n' >"$R/Cargo.toml"
  out="$(bash "$SCRIPTS/run-ci.sh" --dir "$R")"; rc=$?
  eq "run-ci: an unsupported stack exits 3" "$rc" 3
  eq "run-ci: unsupported is explicit" "$(jqv "$out" '.status + ":" + .detected_manifests[0]')" "unsupported:Cargo.toml"

  # suite locking: a held lock makes the test step give up (exit 75 from suite-lock.sh)
  R="$TMP/ci-lock"; newrepo "$R"
  printf 'ci-test:\n\ttrue\n' >"$R/Makefile"
  bash "$SCRIPTS/suite-lock.sh" sleep 6 &
  local holder=$!
  sleep 1
  out="$(HARNESS_SUITE_LOCK_WAIT=1 bash "$SCRIPTS/run-ci.sh" tests --dir "$R")"; rc=$?
  eq "run-ci: a held suite lock stops the test step" "$rc:$(jqv "$out" '.steps[0].exit')" "1:75"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  unset HARNESS_SUITE_LOCK_DIR
}

# ===================================================================== dep-audit.sh
suite_dep_audit() {
  local R out rc D="$TMP/npm-canned"
  mkdir -p "$D"
  export STUB_NPM_DIR="$D"
  cat >"$D/audit.json" <<'EOF'
{"metadata":{"vulnerabilities":{"low":0,"moderate":1,"high":1,"critical":0,"total":2}},
 "vulnerabilities":{"lodash":{"severity":"high","isDirect":true,"range":"<4.17.21","fixAvailable":true,"via":[{"title":"Prototype pollution"}]},
                    "minimist":{"severity":"moderate","isDirect":false,"range":"<1.2.6","fixAvailable":false,"via":["x"]}}}
EOF
  cat >"$D/outdated.json" <<'EOF'
{"react":{"current":"17.0.2","wanted":"17.0.2","latest":"19.0.0","dependent":"app"},
 "zod":{"current":"3.1.0","wanted":"3.1.0","latest":"3.4.0","dependent":"app"},
 "ms":{"current":"2.1.1","wanted":"2.1.3","latest":"2.1.3","dependent":"app"}}
EOF
  R="$TMP/dep-npm"; newrepo "$R"
  printf '{"name":"app","version":"1.0.0"}\n' >"$R/package.json"
  cat >"$R/package-lock.json" <<'EOF'
{"lockfileVersion":3,"packages":{"":{"name":"app"},
 "node_modules/ms":{"version":"2.0.0"},
 "node_modules/a/node_modules/ms":{"version":"2.1.3"},
 "node_modules/a":{"version":"1.0.0"}}}
EOF
  printf 'registry=https://registry.npmjs.org/\n@acme:registry=https://evil.example/npm/\n' >"$R/.npmrc"
  printf 'FROM node\nRUN npm ci\n' >"$R/Dockerfile"
  printf '.git\n' >"$R/.dockerignore"
  mkdir -p "$R/node_modules/gpl-pkg" "$R/node_modules/mit-pkg" "$R/node_modules/post-pkg" "$R/node_modules/gyp-pkg"
  printf '{"name":"gpl-pkg","version":"1.0.0","license":"GPL-3.0"}\n' >"$R/node_modules/gpl-pkg/package.json"
  printf '{"name":"mit-pkg","version":"1.0.0","license":"MIT"}\n' >"$R/node_modules/mit-pkg/package.json"
  printf '{"name":"post-pkg","version":"1.0.0","license":"MIT","scripts":{"postinstall":"node evil.js"}}\n' >"$R/node_modules/post-pkg/package.json"
  printf '{"name":"gyp-pkg","version":"1.0.0","license":"MIT","scripts":{"postinstall":"node-gyp rebuild"}}\n' >"$R/node_modules/gyp-pkg/package.json"
  printf 'node_modules\n' >"$R/.gitignore"
  git -C "$R" add -A && git -C "$R" commit -q -m deps

  : >"$STUB_LOG"
  out="$(bash "$SCRIPTS/dep-audit.sh" --dir "$R")"; rc=$?
  eq "dep-audit: ok exits 0" "$rc:$(jqv "$out" .status)" "0:ok"
  eq "dep-audit: audit counts" "$(jqv "$out" '.vulnerabilities.counts.high')" 1
  eq "dep-audit: a high advisory is P0" "$(jqv "$out" '.vulnerabilities.advisories[] | select(.name == "lodash") | .priority')" P0
  eq "dep-audit: a moderate advisory is P1" "$(jqv "$out" '.vulnerabilities.advisories[] | select(.name == "minimist") | .priority')" P1
  eq "dep-audit: major gap is P1" "$(jqv "$out" '.outdated.packages[] | select(.name == "react") | .gap + .priority')" majorP1
  eq "dep-audit: minor gap is P2" "$(jqv "$out" '.outdated.packages[] | select(.name == "zod") | .gap + .priority')" minorP2
  eq "dep-audit: patch gap is P2" "$(jqv "$out" '.outdated.packages[] | select(.name == "ms") | .gap + .priority')" patchP2
  eq "dep-audit: only the GPL licence is flagged" "$(jqv "$out" '[.licenses.flagged[].package] | join(",")')" gpl-pkg
  eq "dep-audit: only an unexpected install script is listed" "$(jqv "$out" '[.supply_chain.install_scripts[].package] | join(",")')" post-pkg
  eq "dep-audit: a package at two versions is a duplicate" "$(jqv "$out" '.duplicates[0].name + ":" + (.duplicates[0].versions | join("/"))')" "ms:2.0.0/2.1.3"
  eq "dep-audit: the lockfile is committed and in sync" "$(jqv "$out" '.supply_chain.lockfile_committed | tostring')$(jqv "$out" '.supply_chain.lockfile_in_sync | tostring')" truetrue
  eq "dep-audit: a non-default registry is listed" "$(jqv "$out" '.supply_chain.non_default_registries | length')" 1
  eq "dep-audit: Dockerfile without --omit=dev is listed" "$(jqv "$out" '.docker.dockerfiles_without_omit_dev[0]')" Dockerfile
  eq "dep-audit: .dockerignore without node_modules" "$(jqv "$out" '.docker.dockerignore_excludes_node_modules | tostring')" false
  out="$(STUB_NPM_CI_RC=1 bash "$SCRIPTS/dep-audit.sh" --dir "$R")"
  eq "dep-audit: an out-of-sync lockfile is reported" "$(jqv "$out" '.supply_chain.lockfile_in_sync | tostring')" false

  : >"$STUB_LOG"
  out="$(bash "$SCRIPTS/dep-audit.sh" --offline --dir "$R")"
  eq "dep-audit: --offline skips the network calls" "$(jqv "$out" '.vulnerabilities.status + ":" + .outdated.status')" "skipped:skipped"
  eq "dep-audit: --offline calls npm not at all" "$(stublog_lines)" 0

  touch "$R/yarn.lock"
  out="$(bash "$SCRIPTS/dep-audit.sh" --dir "$R")"; rc=$?
  eq "dep-audit: a yarn project is unsupported (exit 3)" "$rc:$(jqv "$out" .status)" "3:unsupported"
  R="$TMP/dep-go"; newrepo "$R"; printf 'module x\n' >"$R/go.mod"
  out="$(bash "$SCRIPTS/dep-audit.sh" --dir "$R")"; rc=$?
  eq "dep-audit: a Go project is unsupported (exit 3)" "$rc:$(jqv "$out" .detected[0])" "3:go.mod"
}

# ===================================================================== stale-reference-scan.sh
suite_stale_ref() {
  local R out rc
  R="$TMP/stale"; mkdir -p "$R/docs" "$R/src" "$R/.claude/commands"
  printf '# T\nRun `npm run build` and `npm run nope`, `make ci`, `make ghost`.\nSee `src/a.ts:12`, `src/missing.ts`, env `API_URL` and `GHOST_VAR`. Use `/deploy` and `/gone`.\nProse mentions make sure and npm run prose-only.\n```bash\nnpm run lint\n```\n' >"$R/docs/x.md"
  echo a >"$R/src/a.ts"; echo 'process.env.API_URL' >"$R/src/b.ts"
  printf '{"scripts":{"build":"x","lint":"y"}}\n' >"$R/package.json"
  printf '.PHONY: ci\nci:\n\ttrue\n' >"$R/Makefile"
  echo '# d' >"$R/.claude/commands/deploy.md"
  printf 'API_URL=1\nUNUSED_VAR=2\n' >"$R/.env.example"
  out="$(bash "$SCRIPTS/stale-reference-scan.sh" --root "$R")"; rc=$?
  eq "stale-ref: scans and exits 0" "$rc:$(jqv "$out" .status)" "0:ok"
  eq "stale-ref: finds exactly the stale references" "$(jqv "$out" '[.stale[] | .type + ":" + .reference] | sort | join(",")')" \
    "command:/gone,env:GHOST_VAR,env:UNUSED_VAR,file:src/missing.ts,make:ghost,script:nope"
  eq "stale-ref: existing references are not reported" "$(jqv "$out" '[.stale[].reference] | map(select(. == "build" or . == "ci" or . == "API_URL" or . == "src/a.ts" or . == "/deploy" or . == "lint")) | length')" 0
  eq "stale-ref: counts the docs with stale references" "$(jqv "$out" .docs_with_stale)" 2
  out="$(bash "$SCRIPTS/stale-reference-scan.sh" --root "$R" docs/x.md)"
  eq "stale-ref: an explicit file limits the scan" "$(jqv "$out" .files_scanned)" 1
  rm -rf "$R/.claude/commands"
  out="$(bash "$SCRIPTS/stale-reference-scan.sh" --root "$R")"
  eq "stale-ref: no commands dir skips command checks" "$(jqv "$out" '.skipped_types[0] + ":" + ([.stale[] | select(.type == "command")] | length | tostring)')" "command:0"
  R="$TMP/stale-none"; mkdir -p "$R"
  out="$(bash "$SCRIPTS/stale-reference-scan.sh" --root "$R")"; rc=$?
  eq "stale-ref: no docs is unsupported (exit 3)" "$rc:$(jqv "$out" .status)" "3:unsupported"
}

# ===================================================================== tech-debt-scan.sh
suite_tech_debt() {
  local R out rc
  R="$TMP/debt"; mkdir -p "$R/apps/api/src" "$R/apps/web" "$R/.claude/tech-debt"
  seq 1 450 | sed 's/^/const a = /' >"$R/apps/api/src/big.ts"
  cat >"$R/apps/api/src/m.ts" <<'EOS'
// TODO(ann): remove after migration to v3
const x = y as any;
try { a() } catch (e) {}
try {
  a()
} catch (e) {
}
console.log('hi')
          if (b) {
                    deep();
          }
// FIXME: bare
// PARKED: later
EOS
  echo "console.log(1) // HACK(jo) #12" >"$R/apps/web/p.tsx"
  echo "console.log('t')" >"$R/apps/web/p.spec.ts"
  echo "apps/api/src/m.ts" >"$R/.claude/tech-debt/a.md"
  out="$(bash "$SCRIPTS/tech-debt-scan.sh" --root "$R")"; rc=$?
  eq "tech-debt: scans and exits 0" "$rc:$(jqv "$out" .status)" "0:ok"
  eq "tech-debt: a file over 400 lines is listed" "$(jqv "$out" '.large_files.items[0].file + ":" + (.large_files.items[0].lines | tostring)')" "apps/api/src/big.ts:450"
  eq "tech-debt: as any is counted" "$(jqv "$out" .totals.type_escapes)" 1
  eq "tech-debt: one-line and multi-line empty catch" "$(jqv "$out" '[.empty_catch.items[].line] | join(",")')" "3,6"
  eq "tech-debt: console skips test files" "$(jqv "$out" '[.console.items[].file] | sort | join(",")')" "apps/api/src/m.ts,apps/web/p.tsx"
  eq "tech-debt: deep nesting is counted per file" "$(jqv "$out" '.deep_nesting.items[0].deep_lines')" 3
  eq "tech-debt: four markers" "$(jqv "$out" '.marker_summary.by_marker | to_entries | map(.key + "=" + (.value | tostring)) | sort | join(",")')" "FIXME=1,HACK=1,PARKED=1,TODO=1"
  eq "tech-debt: owner and plan hint" "$(jqv "$out" '.markers.items[] | select(.marker == "TODO") | .owner + ":" + (.plan_hint | tostring)')" "ann:true"
  eq "tech-debt: PARKED is intentional" "$(jqv "$out" '.markers.items[] | select(.marker == "PARKED") | .intentional | tostring')" true
  eq "tech-debt: category from the path" "$(jqv "$out" '.markers.items[] | select(.marker == "HACK") | .category')" frontend
  eq "tech-debt: registry status" "$(jqv "$out" '[.markers.items[] | .registry_status] | unique | join(",")')" "EXISTING,NEW"
  out="$(bash "$SCRIPTS/tech-debt-scan.sh" --root "$R" --limit 1)"
  eq "tech-debt: --limit trims lists but not totals" "$(jqv "$out" '(.markers.items | length | tostring) + ":" + (.totals.markers | tostring)')" "1:4"
  R="$TMP/debt-py"; mkdir -p "$R"; echo 'print(1)' >"$R/a.py"
  out="$(bash "$SCRIPTS/tech-debt-scan.sh" --root "$R")"; rc=$?
  eq "tech-debt: no JS/TS source is unsupported (exit 3)" "$rc:$(jqv "$out" .status)" "3:unsupported"
}

# ===================================================================== endpoint-inventory.sh
suite_endpoints() {
  local R out rc
  R="$TMP/nest"; mkdir -p "$R/apps/api/src/invoices"
  echo "app.setGlobalPrefix('api');" >"$R/apps/api/src/main.ts"
  cat >"$R/apps/api/src/invoices/invoices.controller.ts" <<'EOS'
@UseGuards(AuthGuard)
@Controller('invoices')
export class InvoicesController {
  @Get()
  list(@Query() q: ListDto, @CurrentUser() user: User) {
    return [];
  }

  @Public()
  @Get(':id')
  one(@Param('id', ParseUUIDPipe) id: string) {
    return 1;
  }

  @Post()
  create(
    @Body(new ZodValidationPipe(S)) body: B,
    @Param('x') x: string,
  ): Promise<void> {
    return;
  }
}
EOS
  out="$(cd "$R" && bash "$SCRIPTS/endpoint-inventory.sh")"; rc=$?
  eq "endpoints: scans and exits 0" "$rc:$(jqv "$out" .framework)" "0:nestjs"
  eq "endpoints: three routes with the global prefix" "$(jqv "$out" '[.endpoints[] | .method + " " + .path] | join(",")')" "GET /api/invoices,GET /api/invoices/:id,POST /api/invoices"
  eq "endpoints: @Public on the method" "$(jqv "$out" '[.endpoints[] | .auth] | join(",")')" "protected,public,protected"
  eq "endpoints: unvalidated query" "$(jqv "$out" '.endpoints[0].query_validation')" no
  eq "endpoints: a Parse pipe validates a param" "$(jqv "$out" '.endpoints[1].param_validation')" yes
  eq "endpoints: a Zod pipe validates the body, a bare param does not" "$(jqv "$out" '.endpoints[2].body_validation + "/" + .endpoints[2].param_validation')" "yes/no"
  eq "endpoints: CurrentUser is noticed" "$(jqv "$out" '.endpoints[0].current_user | tostring')" true
  eq "endpoints: totals" "$(jqv "$out" '.totals | [.endpoints, .public, .unvalidated_param, .unvalidated_query] | map(tostring) | join(",")')" "3,1,1,1"
  out="$(cd "$R" && bash "$SCRIPTS/endpoint-inventory.sh" --prefix v2)"
  eq "endpoints: --prefix overrides main.ts" "$(jqv "$out" '.endpoints[0].path')" "/v2/invoices"
  R="$TMP/express"; mkdir -p "$R/src"; echo "app.get('/x', h)" >"$R/src/app.js"
  out="$(cd "$R" && bash "$SCRIPTS/endpoint-inventory.sh")"; rc=$?
  eq "endpoints: another framework is unsupported (exit 3)" "$rc:$(jqv "$out" .status)" "3:unsupported"
}

# ===================================================================== copywrite-checks.sh
suite_copywrite() {
  local C="$SCRIPTS/copywrite-checks.sh" R out rc
  R="$TMP/cw"; mkdir -p "$R/node_modules/@formatjs/icu-messageformat-parser" "$R/node_modules/@babel/parser"
  # stand-ins for the two parser packages: the ICU stub compares the number of "{" in the strings,
  # the Babel stub rejects any source that contains SYNTAX_ERROR
  cat >"$R/node_modules/@formatjs/icu-messageformat-parser/index.js" <<'EOS'
exports.parse = (s) => ({ braces: (s.match(/\{/g) || []).length });
exports.isStructurallySame = (a, b) => (a.braces === b.braces ? { success: true } : { success: false, error: { message: "shape changed" } });
EOS
  cat >"$R/node_modules/@babel/parser/index.js" <<'EOS'
exports.parse = (src) => { if (src.indexOf("SYNTAX_ERROR") >= 0) throw new Error("Unexpected token (1:1)"); return {}; };
EOS

  out="$(bash "$C" dash --old "Pay now" --new "Pay now. Done")"; rc=$?
  eq "copywrite dash: no dash passes" "$rc:$(jqv "$out" .ok)" "0:true"
  out="$(bash "$C" dash --old "Pay now" --new "Pay now — done")"; rc=$?
  eq "copywrite dash: a new em dash fails" "$rc:$(jqv "$out" '.introduced[0]')" "1:em dash"
  out="$(bash "$C" dash --old "A–B" --new "A–B and C")"; rc=$?
  eq "copywrite dash: an existing en dash is allowed" "$rc" 0
  out="$(bash "$C" dash --old "A–B" --new "A–B–C")"; rc=$?
  eq "copywrite dash: a second en dash fails" "$rc:$(jqv "$out" '.introduced[0]')" "1:en dash"
  printf 'x — y' >"$R/new.txt"
  out="$(bash "$C" dash --old "x" --new "@$R/new.txt")"; rc=$?
  eq "copywrite dash: @file values are read" "$rc" 1

  out="$(bash "$C" icu --old "Hello" --new "Hi" --resolve-from "$R")"; rc=$?
  eq "copywrite icu: plain text skips the parser" "$rc:$(jqv "$out" '.skipped != null | tostring')" "0:true"
  out="$(bash "$C" icu --old "{n, plural, one {# item} other {# items}}" --new "{n, plural, one {# thing} other {# things}}" --resolve-from "$R")"; rc=$?
  eq "copywrite icu: same structure passes" "$rc:$(jqv "$out" .ok)" "0:true"
  out="$(bash "$C" icu --old "{n, plural, one {# item} other {# items}}" --new "# items" --resolve-from "$R")"; rc=$?
  eq "copywrite icu: changed structure fails" "$rc:$(jqv "$out" .reason)" "1:shape changed"
  out="$(bash "$C" icu --old "{n, plural, one {a} other {b}}" --new "x" --resolve-from "$TMP")"; rc=$?
  eq "copywrite icu: a missing parser is unsupported (exit 3)" "$rc:$(jqv "$out" .status)" "3:unsupported"

  printf 'export const A = () => <b>ok</b>;\n' >"$R/ok.tsx"
  printf 'SYNTAX_ERROR\n' >"$R/bad.tsx"
  out="$(bash "$C" babel --file "$R/ok.tsx" --resolve-from "$R")"; rc=$?
  eq "copywrite babel: a parsable file passes" "$rc:$(jqv "$out" .ok)" "0:true"
  out="$(bash "$C" babel --file "$R/bad.tsx" --resolve-from "$R")"; rc=$?
  eq "copywrite babel: a parse failure fails" "$rc:$(jqv "$out" .reason)" "1:Unexpected token (1:1)"
  printf 'SYNTAX_ERROR\n' >"$R/x.json"
  out="$(bash "$C" babel --file "$R/x.json" --resolve-from "$R")"; rc=$?
  eq "copywrite babel: other extensions are skipped" "$rc:$(jqv "$out" '.skipped != null | tostring')" "0:true"
  out="$(bash "$C" babel --file "$R/ok.tsx" --resolve-from "$TMP")"; rc=$?
  eq "copywrite babel: a missing parser is unsupported (exit 3)" "$rc:$(jqv "$out" .status)" "3:unsupported"

  printf 'Primește factura țării\n' >"$R/before.txt"
  printf 'Primeste factura tarii\n' >"$R/after.txt"
  out="$(bash "$C" diacritics --class 'ăâîșțĂÂÎȘȚ' --before-file "$R/before.txt" --after-file "$R/after.txt")"; rc=$?
  eq "copywrite diacritics: a drop fails" "$rc:$(jqv "$out" '(.before | tostring) + "/" + (.after | tostring)')" "1:3/0"
  out="$(bash "$C" diacritics --class 'ăâîșțĂÂÎȘȚ' --before-file "$R/before.txt" --after-file "$R/before.txt")"; rc=$?
  eq "copywrite diacritics: no drop passes" "$rc" 0

  printf '{"a":{"b":"x","c":"y"},"d":"z"}\n' >"$R/en.json"
  printf '{"a":{"b":"x"},"d":"z","e":"w"}\n' >"$R/ro.json"
  out="$(bash "$C" parity --a "$R/en.json" --b "$R/ro.json")"; rc=$?
  eq "copywrite parity: differing keys fail" "$rc:$(jqv "$out" '(.missing_in_b | join(",")) + "|" + (.missing_in_a | join(","))')" "1:a.c|e"
  out="$(bash "$C" parity --a "$R/en.json" --b "$R/ro.json" --keys a.b,d)"; rc=$?
  eq "copywrite parity: --keys limits the check" "$rc" 0
  out="$(bash "$C" parity --a "$R/en.json" --b "$R/ro.json" --keys a.c)"; rc=$?
  eq "copywrite parity: a changed key absent from the sibling fails" "$rc:$(jqv "$out" '.missing_in_b[0]')" "1:a.c"

  cat >"$R/brand.md" <<'EOS'
# Glossary
| Term | Locale A | Locale B | Notes |
|---|---|---|---|
| `Acme Pay` | | | the product |
| `eFactura` | `eFactura` | `e-Factura` | regulatory |
| `[Placeholder]` | | | |
EOS
  printf 'Use Acme Pay and e-Factura. Never acme pay or Efactura.\n' >"$R/copy.txt"
  out="$(bash "$C" glossary --terms "$R/brand.md" --text "$R/copy.txt")"; rc=$?
  eq "copywrite glossary: miscapitalised terms fail" "$rc:$(jqv "$out" '[.violations[].found] | sort | join(",")')" "1:Efactura,acme pay"
  printf 'Use Acme Pay and e-Factura.\n' >"$R/copy.txt"
  out="$(bash "$C" glossary --terms "$R/brand.md" --text "$R/copy.txt")"; rc=$?
  eq "copywrite glossary: canonical spellings pass" "$rc" 0
  bash "$C" bogus >/dev/null 2>&1; rc=$?
  eq "copywrite: an unknown gate exits 2" "$rc" 2
}

# ===================================================================== sections
# SECTIONS-BEGIN
suite_run_ci
suite_dep_audit
suite_stale_ref
suite_tech_debt
suite_endpoints
suite_copywrite
# SECTIONS-END

PATH="$ORIG_PATH"
if [ "$FAILS" -gt 0 ]; then echo "$FAILS case(s) failed"; exit 1; fi
