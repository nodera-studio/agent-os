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

# ===================================================================== blind-candidates.sh
suite_blind() {
  local B="$SCRIPTS/blind-candidates.sh" R out rc s first seen_claude=0 seen_codex=0
  R="$TMP/blind"; mkdir -p "$R"
  printf '# Plan\nI ran Codex to check this. As Claude I think gpt-5.1 and claude-opus-4 agree.\nThe compiler (complex) is fine.\n**Session ID**: 123e4567-e89b-12d3-a456-426614174000\nGenerated by Codex\njob task-abc12345 done\nKeep Gemini here.\n' >"$R/r1.md"
  printf 'Substance B with Opus and the omp engine.\n' >"$R/r2.md"
  printf 'Third candidate.\n' >"$R/r3.md"

  out="$(bash "$B" --kind arch --slug t1 --dir "$R/plans" --seed 3 claude="$R/r1.md" codex="$R/r2.md")"; rc=$?
  eq "blind: runs and exits 0" "$rc:$(jqv "$out" '.candidates | length')" "0:2"
  eq "blind: arch names are <slug>.arch-a.md and -b.md" "$(jqv "$out" '[.candidates[].path | split("/") | last] | join(",")')" "t1.arch-a.md,t1.arch-b.md"
  eq "blind: the order is not printed" "$(printf '%s' "$out" | grep -ci 'claude\|codex')" 0
  eq "blind: the mapping is recorded privately" "$(cat "$R/plans/t1.private/mapping.md")" "arch: A=claude B=codex"
  eq "blind: raw outputs are kept verbatim, with engine suffixes" "$(cmp -s "$R/r1.md" "$R/plans/t1.private/arch-claude.md" && cmp -s "$R/r2.md" "$R/plans/t1.private/arch-codex.md" && echo same)" same
  [ ! -e "$R/plans/t1.private/claude.md" ] && ok "blind: no bare claude.md is written" || fail "blind: a bare claude.md exists"
  a="$(cat "$R/plans/t1.arch-a.md" "$R/plans/t1.arch-b.md")"
  lacks "blind: engine and model names are stripped" "$a" "Codex"
  lacks "blind: model names with a version suffix go too" "$a" "gpt-5"
  lacks "blind: a Session ID line is dropped" "$a" "123e4567"
  lacks "blind: a Generated by footer is dropped" "$a" "Generated by"
  lacks "blind: a task id is replaced" "$a" "abc12345"
  has "blind: a word that merely contains a tell is untouched" "$a" "The compiler (complex) is fine."
  eq "blind: no residual tells" "$(jqv "$out" .residual_tells)" 0

  out="$(bash "$B" --kind arch --slug t1 --dir "$R/plans" claude="$R/r1.md" codex="$R/r2.md" 2>&1)"; rc=$?
  eq "blind: refuses to re-shuffle existing copies" "$rc" 2
  out="$(bash "$B" --kind arch --slug t1 --dir "$R/plans" --force --seed 3 claude="$R/r1.md" codex="$R/r2.md")"; rc=$?
  eq "blind: --force overwrites" "$rc" 0

  out="$(bash "$B" --kind plan --slug t2 --dir "$R/plans" --keep gemini claude="$R/r1.md" codex="$R/r2.md" other="$R/r3.md")"
  eq "blind: plan names and three candidates" "$(jqv "$out" '[.candidates[].path | split("/") | last] | join(",")')" "t2.candidate-a.md,t2.candidate-b.md,t2.candidate-c.md"
  eq "blind: --keep leaves the term and reports the residual" "$(jqv "$out" .residual_tells)" 1
  eq "blind: three-way mapping has three labels" "$(grep -c 'A=.* B=.* C=' "$R/plans/t2.private/mapping.md")" 1

  for s in 1 2 3 4 5 6 7 8 9 10 11 12; do
    bash "$B" --kind arch --slug "s$s" --dir "$R/plans" --seed "$s" claude="$R/r1.md" codex="$R/r2.md" >/dev/null
    first="$(sed 's/^arch: A=\([a-z]*\).*/\1/' "$R/plans/s$s.private/mapping.md")"
    [ "$first" = claude ] && seen_claude=1
    [ "$first" = codex ] && seen_codex=1
  done
  eq "blind: both orders occur across seeds" "$seen_claude$seen_codex" 11
  out="$(bash "$B" --kind arch --slug t3 --dir "$R/plans" only="$R/r1.md" 2>&1)"; rc=$?
  eq "blind: one candidate is refused" "$rc" 2
}

# ===================================================================== release scripts
# A gh stub that serves canned JSON from $STUB_GH_DIR, logs every call, and answers any call that
# would post, merge, create or otherwise write with exit 99 and a FORBIDDEN line in the log.
cat >"$STUBS/gh" <<'EOS'
#!/bin/bash
echo "gh $*" >>"$STUB_LOG"
D="${STUB_GH_DIR:-/nonexistent}"
forbid() { echo FORBIDDEN >>"$STUB_LOG"; exit 99; }
case "$1" in
  run) [ "$2" = list ] && { cat "$D/runlist.json"; exit 0; } ;;
  api)
    [ -z "${STUB_GH_FAIL:-}" ] || exit 1
    for a in "$@"; do case "$a" in -X | -f | -F | --method | --field | --raw-field | --input) forbid ;; esac; done
    case "$*" in
      *"/reviews"*) cat "$D/reviews.json" ;;
      *"/issues/"*) cat "$D/issue.json" ;;
      *"/pulls/"*"/comments"*) cat "$D/inline.json" ;;
    esac
    exit 0 ;;
  pr)
    case "$2" in
      checks) cat "$D/checks.json"; exit 1 ;;
      view) f="$D/pr-$3.txt"; [ -f "$f" ] || exit 1
        case "$*" in *headRefName*) cat "$f" ;; *) cut -d' ' -f1 "$f" ;; esac
        exit 0 ;;
    esac ;;
esac
forbid
EOS
chmod +x "$STUBS/gh"

suite_seam() {
  local R out rc
  printf 'src/a.ts\nsrc/b.ts\nregistry.ts\n' >"$TMP/seam-a.txt"
  printf 'registry.ts\nsrc/c.ts\nsrc/a.ts\n\n' >"$TMP/seam-b.txt"
  out="$(bash "$SCRIPTS/seam-overlap.sh" "$TMP/seam-a.txt" "$TMP/seam-b.txt")"; rc=$?
  eq "seam: two lists overlap (exit 1)" "$rc:$(jqv "$out" '.overlap | join(",")')" "1:registry.ts,src/a.ts"
  printf 'x.ts\n' >"$TMP/seam-c.txt"
  out="$(bash "$SCRIPTS/seam-overlap.sh" "$TMP/seam-a.txt" "$TMP/seam-c.txt")"; rc=$?
  eq "seam: disjoint lists exit 0" "$rc:$(jqv "$out" .count)" "0:0"
  R="$TMP/seam-repo"; newrepo "$R"
  git -C "$R" switch -q -c wa; echo 1 >"$R/shared.ts"; echo 1 >"$R/only-a.ts"; git -C "$R" add -A; git -C "$R" commit -q -m a
  git -C "$R" switch -q main; git -C "$R" switch -q -c wb; echo 2 >"$R/shared.ts"; echo 2 >"$R/only-b.ts"; git -C "$R" add -A; git -C "$R" commit -q -m b
  out="$(bash "$SCRIPTS/seam-overlap.sh" --repo "$R" --trunk main --branch wa --branch wb)"; rc=$?
  eq "seam: two branches overlap on the shared file" "$rc:$(jqv "$out" '.overlap | join(",")')" "1:shared.ts"
  bash "$SCRIPTS/seam-overlap.sh" "$TMP/seam-a.txt" >/dev/null 2>&1; rc=$?
  eq "seam: one list is a usage error" "$rc" 2
}

suite_promote() {
  local O="$TMP/promote-origin.git" W="$TMP/promote-work" G="$TMP/gh-promote" out rc
  mkdir -p "$G"
  git init -q --bare -b main "$O"
  git clone -q "$O" "$W" 2>/dev/null
  git -C "$W" switch -q -c main 2>/dev/null || true
  echo 0 >"$W/f"; git -C "$W" add -A; git -C "$W" commit -q -m "base"; git -C "$W" push -q origin main
  git -C "$W" switch -q -c staging
  echo 1 >"$W/f"; git -C "$W" commit -q -am "feat: ABC-1 first"
  echo 2 >"$W/f"; git -C "$W" commit -q -am "fix: ABC-2 second (#3)"
  echo 3 >"$W/f"; git -C "$W" commit -q -am "ABC-1 again"
  git -C "$W" push -q origin staging
  local S; S="$(git -C "$W" rev-parse origin/staging)"
  export STUB_GH_DIR="$G"
  pf() { (cd "$W" && bash "$SCRIPTS/promote-preflight.sh" --prod main --staging staging --workflow ci --ticket-prefix ABC "$@"); }

  printf '[{"status":"completed","conclusion":"success","headSha":"%s","url":"https://ci/1"}]\n' "$S" >"$G/runlist.json"
  : >"$STUB_LOG"
  out="$(pf)"; rc=$?
  eq "promote: green run for the head is ready (exit 0)" "$rc:$(jqv "$out" .status)" "0:ready"
  eq "promote: counts and tickets" "$(jqv "$out" '(.promote_count | tostring) + ":" + (.drift_count | tostring) + ":" + (.tickets | join(","))')" "3:0:ABC-1,ABC-2"
  eq "promote: only a CI read goes through gh" "$(grep -c '^gh ' "$STUB_LOG"):$(grep -c 'run list' "$STUB_LOG"):$(grep -c FORBIDDEN "$STUB_LOG")" "1:1:0"
  out="$(pf --no-fetch | jq -r .status)"
  eq "promote: --no-fetch still works" "$out" ready

  printf '[{"status":"completed","conclusion":"success","headSha":"0000000000000000000000000000000000000000","url":"u"}]\n' >"$G/runlist.json"
  out="$(pf)"; rc=$?
  eq "promote: a green run of another commit is stale (exit 1)" "$rc:$(jqv "$out" .ci.state)" "1:stale"
  printf '[{"status":"completed","conclusion":"failure","headSha":"%s","url":"u"}]\n' "$S" >"$G/runlist.json"
  out="$(pf)"; eq "promote: a red run blocks" "$(jqv "$out" '.status + ":" + .ci.state')" "blocked:failed"
  printf '[{"status":"in_progress","conclusion":null,"headSha":"%s","url":"u"}]\n' "$S" >"$G/runlist.json"
  out="$(pf)"; eq "promote: a running CI blocks" "$(jqv "$out" .ci.state)" running
  echo '[]' >"$G/runlist.json"
  out="$(pf)"; eq "promote: no run blocks" "$(jqv "$out" .ci.state)" none

  printf '[{"status":"completed","conclusion":"success","headSha":"%s","url":"u"}]\n' "$S" >"$G/runlist.json"
  git -C "$W" switch -q main; echo hot >"$W/hot"; git -C "$W" add -A; git -C "$W" commit -q -m "hotfix on main"; git -C "$W" push -q origin main
  out="$(pf)"; rc=$?
  eq "promote: a feature commit on the release branch is drift (exit 1)" "$rc:$(jqv "$out" .drift_count)" "1:1"
  out="$(cd "$W" && bash "$SCRIPTS/promote-preflight.sh" --prod main --staging staging --workflow ci)"
  eq "promote: no ticket prefix skips the list" "$(jqv "$out" '.tickets_skipped | tostring')" true
  (cd "$W" && bash "$SCRIPTS/promote-preflight.sh" --prod main --staging staging >/dev/null 2>&1); rc=$?
  eq "promote: --workflow is required (exit 2)" "$rc" 2
  if (PATH=/usr/bin:/bin; command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1); then
    echo "skip promote: gh-missing case (gh, or jq or git, is on the minimal PATH)"
  else
    out="$(cd "$W" && PATH=/usr/bin:/bin bash "$SCRIPTS/promote-preflight.sh" --prod main --staging staging --workflow ci)"; rc=$?
    eq "promote: no gh is unsupported (exit 3)" "$rc:$(jqv "$out" .status)" "3:unsupported"
  fi
  unset STUB_GH_DIR
}

suite_poll() {
  local G="$TMP/gh-poll" ST="$TMP/poll-state.md" out rc
  mkdir -p "$G"
  export STUB_GH_DIR="$G"
  cat >"$G/inline.json" <<'EOS'
[{"id":1,"user":{"login":"alice","type":"User"},"created_at":"2026-01-01T10:00:00Z","path":"a.ts","line":3,"body":"nit","html_url":"u1"},
 {"id":2,"user":{"login":"cr[bot]","type":"Bot"},"created_at":"2026-01-01T11:00:00Z","path":"b.ts","line":null,"original_line":9,"body":"bot says","html_url":"u2"}]
EOS
  echo '[{"id":3,"user":{"login":"bob","type":"User"},"created_at":"2026-01-01T12:00:00Z","body":"hi","html_url":"u3"}]' >"$G/issue.json"
  cat >"$G/reviews.json" <<'EOS'
[{"id":4,"user":{"login":"alice","type":"User"},"submitted_at":"2026-01-01T13:00:00Z","state":"CHANGES_REQUESTED","body":"fix","html_url":"u4"},
 {"id":5,"user":{"login":"bob","type":"User"},"submitted_at":"2026-01-01T09:00:00Z","state":"COMMENTED","body":"","html_url":"u5"}]
EOS
  echo '[{"name":"Build","bucket":"fail"},{"name":"Lint","bucket":"pass"}]' >"$G/checks.json"
  cp "$SCRIPTS/../templates/auto-mode-state.md" "$ST"
  : >"$STUB_LOG"
  out="$(bash "$SCRIPTS/poll-pr.sh" 7 --state "$ST")"; rc=$?
  eq "poll: the first cycle prints (exit 0)" "$rc" 0
  eq "poll: four new items, the empty COMMENTED review skipped" "$(jqv "$out" '[.new_comments[] | .kind] | sort | join(",")')" "inline,inline,issue,review"
  eq "poll: a bot is flagged and the line falls back to original_line" "$(jqv "$out" '.new_comments[] | select(.user == "cr[bot]") | (.bot | tostring) + ":" + (.line | tostring)')" "true:9"
  eq "poll: checks changed, the failing one named" "$(jqv "$out" '(.checks.changed | tostring) + ":" + (.checks.failing | join(","))')" "true:Build"
  eq "poll: not clean" "$(jqv "$out" '.clean | tostring')" false
  eq "poll: the cursor moved to the newest item" "$(sed -n 's/^- PR #7 last-seen comment: //p' "$ST")" "2026-01-01T13:00:00Z"
  has "poll: the checks signature is stored" "$(grep 'PR #7 last-seen checks' "$ST")" "last-seen checks: "
  out="$(bash "$SCRIPTS/poll-pr.sh" 7 --state "$ST")"; rc=$?
  eq "poll: a quiet cycle prints nothing (exit 1)" "$rc:${out:-empty}" "1:empty"
  out="$(bash "$SCRIPTS/poll-pr.sh" 7 --state "$ST" --always)"; rc=$?
  eq "poll: --always prints a quiet cycle" "$rc:$(jqv "$out" '.new_comments | length')" "0:0"
  echo '[{"id":6,"user":{"login":"bob","type":"User"},"created_at":"2026-01-01T14:00:00Z","body":"later","html_url":"u6"}]' >"$G/issue.json"
  before="$(cat "$ST")"
  out="$(bash "$SCRIPTS/poll-pr.sh" 7 --state "$ST" --no-advance)"
  eq "poll: --no-advance sees the new comment but keeps the cursor" "$(jqv "$out" '.new_comments | length'):$([ "$(cat "$ST")" = "$before" ] && echo same)" "1:same"
  out="$(bash "$SCRIPTS/poll-pr.sh" 7 --state "$ST")"
  eq "poll: only the new comment is printed, checks unchanged" "$(jqv "$out" '(.new_comments | length | tostring) + ":" + (.checks.changed | tostring)')" "1:false"
  echo '[{"name":"Build","bucket":"pass"},{"name":"Lint","bucket":"pass"}]' >"$G/checks.json"
  out="$(bash "$SCRIPTS/poll-pr.sh" 7 --state "$ST")"
  eq "poll: green checks with nothing new are a clean cycle" "$(jqv "$out" '(.clean | tostring) + ":" + (.checks.all_green | tostring)')" "true:true"
  out="$(STUB_GH_FAIL=1 bash "$SCRIPTS/poll-pr.sh" 7 --state "$ST" 2>&1)"; rc=$?
  eq "poll: a gh failure is an error, not a quiet cycle (exit 2)" "$rc" 2
  out="$(bash "$SCRIPTS/poll-pr.sh" 7 --state "$TMP/no-such-state.md")"
  eq "poll: without a state file nothing persists" "$(jqv "$out" '.cursor.persisted | tostring')" false
  eq "poll: gh only reads" "$(grep -c FORBIDDEN "$STUB_LOG")" 0
  bash "$SCRIPTS/poll-pr.sh" x >/dev/null 2>&1; rc=$?
  eq "poll: a bad PR number is a usage error" "$rc" 2
  unset STUB_GH_DIR
}

suite_close_run() {
  local W="$TMP/close" R O G out rc sp1 sp2 dead cond
  R="$W/repo"; O="$W/origin.git"; G="$W/gh"
  mkdir -p "$W/tmp" "$W/plugin/state" "$G" "$R/.claude/scripts/lib" "$R/.claude/auto-mode"
  export STUB_GH_DIR="$G"
  git init -q --bare -b main "$O"
  git init -q -b main "$R"
  printf '.claude/worktrees/\n.claude/evidence/\n.claude/auto-mode/\n' >"$R/.gitignore"
  cp "$SCRIPTS/close-run.sh" "$SCRIPTS/remove-worktree.sh" "$SCRIPTS/sweep-codex-orphans.sh" "$SCRIPTS/clean-scratch.sh" "$SCRIPTS/codex-procs.sh" "$R/.claude/scripts/"
  cp "$SCRIPTS/lib/proc-common.sh" "$R/.claude/scripts/lib/"
  git -C "$R" add -A; git -C "$R" commit -q -m init
  git -C "$R" remote add origin "$O"; git -C "$R" push -q origin main
  for b in feat/a feat/b staging; do git -C "$R" push -q origin "main:refs/heads/$b"; done
  git -C "$R" worktree add -q "$R/.claude/worktrees/w1" -b wave-w1 >/dev/null 2>&1
  git -C "$R" push -q origin wave-w1

  sleep 300 & sp1=$!
  sleep 301 & sp2=$!
  true & dead=$!; wait "$dead"
  ls1="$(ps -o lstart= -p "$sp1" | tr -s ' ' | sed 's/^ //; s/ $//')"
  cat >"$R/.claude/auto-mode/state.md" <<EOS
# Auto-Mode State

## Goal

ship it

## Status

landing

## Wave ledger

| Wave | Ticket | Branch | PR → staging | State |
| ---- | ------ | ------ | ------------ | ----- |
| 1 | T-1 | feat/a | #11 | merged |
| 2 | T-2 | feat/b | #12 | polling |
| 3 | T-3 | staging | #13 | merged |

## Harness self-improvement

| Batch | Branch | Worktree | PR → staging | State |
| ----- | ------ | -------- | ------------ | ----- |
| 1 | wave-w1 | .claude/worktrees/w1 | #14 | merged |

## Checkpoints

- Cadence: 60m
- Last checkpoint: none
- Path: docs/cp.md
- Schedule: cron-77

## Processes started

| pid | started (ps lstart) | command | why | stopped |
| --- | --- | --- | --- | --- |
| $sp1 | $ls1 | sleep 300 | preview | |
| $sp2 | Mon Jan  1 00:00:00 2001 | sleep 301 | stale row | |
| $dead | Mon Jan  1 00:00:00 2001 | gone | finished | |
EOS
  printf 'MERGED feat/a\n' >"$G/pr-11.txt"; printf 'OPEN feat/b\n' >"$G/pr-12.txt"
  printf 'MERGED staging\n' >"$G/pr-13.txt"; printf 'MERGED wave-w1\n' >"$G/pr-14.txt"
  printf 'MERGED closing\n' >"$G/pr-99.txt"; printf 'OPEN closing\n' >"$G/pr-98.txt"
  mkdir -p "$W/tmp/autosmoke-run1" "$W/tmp/autosmoke-other"
  echo x >"$W/tmp/autosmoke-run1/f"; echo x >"$W/tmp/autosmoke-other/f"
  touch -t 202001010000 "$W/tmp/autosmoke-run1/f" "$W/tmp/autosmoke-run1" "$W/tmp/autosmoke-other/f" "$W/tmp/autosmoke-other"
  cp "$R/.claude/auto-mode/state.md" "$W/state.orig"
  cr() { (cd "$R" && env TMPDIR="$W/tmp" CLAUDE_PLUGIN_DATA="$W/plugin" bash "$R/.claude/scripts/close-run.sh" --trunk staging --prod main "$@"); }

  : >"$STUB_LOG"
  out="$(cr)"; rc=$?
  eq "close-run: the plan lists what it would do" "$(jqv "$out" '.mode + ":" + ([.processes[].action] | sort | join(","))')" "plan:gone,reused-pid,would-stop"
  eq "close-run: plan changes nothing" "$(cmp -s "$R/.claude/auto-mode/state.md" "$W/state.orig" && echo same):$(kill -0 "$sp1" 2>/dev/null && echo alive)" "same:alive"
  eq "close-run: the plan marks merged PR branches, protects the trunk, skips an open PR" \
    "$(jqv "$out" '[.branches[] | .subject + "=" + .action] | sort | join(",")')" "#11=would-delete,#12=skipped,#13=skipped,#14=would-delete"
  eq "close-run: the plan only dry-runs the worktree" "$(jqv "$out" '.worktrees[0].action'):$([ -d "$R/.claude/worktrees/w1" ] && echo present)" "would-remove:present"
  eq "close-run: the remote branches are untouched in a plan" "$(git -C "$O" branch --list | tr -d ' *\n')" "feat/afeat/bmainstagingwave-w1"
  has "close-run: the schedule id is returned for CronDelete" "$(jqv "$out" '.manual | join("|")')" "cron-77"
  eq "close-run: scratch is listed, not cleaned, in a plan" "$([ -d "$W/tmp/autosmoke-run1" ] && echo kept)" kept

  out="$(cr --apply --scratch-pattern autosmoke-run1)"; rc=$?
  eq "close-run: apply stops the matching process only" "$(kill -0 "$sp1" 2>/dev/null && echo alive || echo stopped):$(kill -0 "$sp2" 2>/dev/null && echo alive)" "stopped:alive"
  eq "close-run: apply fills stopped for the stopped and the gone rows, not the reused pid" \
    "$(grep -c '^| [0-9]* |.*| [0-9T:Z-]*\( (already gone)\)\? |$' "$R/.claude/auto-mode/state.md")" 2
  eq "close-run: apply removes the worktree" "$([ -d "$R/.claude/worktrees/w1" ] && echo present || echo removed)" removed
  eq "close-run: apply deletes only merged non-protected branches" "$(git -C "$O" branch --list | tr -d ' *\n')" "feat/bmainstaging"
  if command -v lsof >/dev/null 2>&1; then
    eq "close-run: apply cleans only the named scratch entry" "$([ -d "$W/tmp/autosmoke-run1" ] && echo run1)$([ -d "$W/tmp/autosmoke-other" ] && echo other)" other
  else
    echo "skip close-run: scratch cleanup (lsof is missing)"
  fi
  eq "close-run: a live reused-pid row is never signalled" "$(kill -0 "$sp2" 2>/dev/null && echo alive)" alive
  eq "close-run: the reused pid is reported and the run is clean (exit 0)" "$(jqv "$out" '.processes[] | select(.action == "reused-pid") | .subject'):$rc" "$sp2:0"
  eq "close-run: gh only reads" "$(grep -c FORBIDDEN "$STUB_LOG")" 0

  # finalize: needs --apply, a MERGED closing PR, and no blocked step
  kill "$sp2" 2>/dev/null; wait "$sp2" 2>/dev/null
  out="$(cr --apply --skip worktrees --skip scratch --skip branches --finalize-state --closing-pr 98)"; rc=$?
  eq "close-run: an unmerged closing PR leaves the state alone" "$rc:$(jqv "$out" '.finalize.applied | tostring'):$(grep -c 'Cadence: 60m' "$R/.claude/auto-mode/state.md")" "1:false:1"
  out="$(cr --apply --skip worktrees --skip scratch --skip branches --finalize-state --closing-pr 99)"; rc=$?
  cond="$(sed -n '/^## Status/,/^## Wave/p' "$R/.claude/auto-mode/state.md" | grep -c '^done$')"
  eq "close-run: a merged closing PR finalises the state file" "$rc:$(jqv "$out" '.finalize.applied | tostring'):$cond:$(grep -c 'Cadence: none' "$R/.claude/auto-mode/state.md"):$(grep -c 'Schedule: none' "$R/.claude/auto-mode/state.md")" "0:true:1:1:1"
  bash "$SCRIPTS/checkpoint-due.sh" "$SCRIPTS/../templates/auto-mode-state.md" >/dev/null 2>&1; rc=$?
  eq "close-run: the state template parses (checkpoint-due exit 3 = no cadence)" "$rc" 3
  unset STUB_GH_DIR
}

# ===================================================================== mnemosyne/capture-findings.sh
suite_capture() {
  local C="$SCRIPTS/mnemosyne/capture-findings.sh" W="$TMP/capture" out rc recs
  mkdir -p "$W"
  cat >"$W/findings.json" <<'EOS'
[{"finding":"  Missing  tenant\nfilter in list() ","category":"Tenant Isolation","file":"./apps/api/a.ts:42","must_fix":true,"engine":"codex"},
 {"text":"Rename var","file":"b.ts"},
 {"description":"Old bug","file":"c.ts","pre_existing":true},
 {"finding":"Dropped idea","action":"dismissed","file":"d.ts"},
 {"finding":"","file":"e.ts"},
 {"finding":"Odd action","action":"bogus","must_fix":true}]
EOS
  out="$(bash "$C" --session s1 --source synthesizer --commit abc1234 --input "$W/findings.json" --dry-run)"; rc=$?
  eq "capture: dry-run exits 0 and prints four records" "$rc:$(printf '%s\n' "$out" | grep -c .)" "0:4"
  recs="$(printf '%s\n' "$out" | jq -s .)"
  eq "capture: text is whitespace-collapsed" "$(jqv "$recs" '.[0].finding_text')" "Missing tenant filter in list()"
  eq "capture: category is kebab-cased, file loses ./ and :line" "$(jqv "$recs" '.[0].category + "|" + .[0].file')" "tenant-isolation|apps/api/a.ts"
  eq "capture: must_fix maps to action must_fix, accepted true" "$(jqv "$recs" '.[0].action + ":" + (.[0].accepted | tostring)')" "must_fix:true"
  eq "capture: no flag maps to note, accepted false" "$(jqv "$recs" '.[1].action + ":" + (.[1].accepted | tostring)')" "note:false"
  eq "capture: an explicit dismissed is kept" "$(jqv "$recs" '.[2].action')" dismissed
  eq "capture: an invalid action falls back to must_fix when flagged" "$(jqv "$recs" '.[3].action')" must_fix
  eq "capture: source, engine, session and commit are stamped" "$(jqv "$recs" '.[0].source + "|" + .[0].engine + "|" + .[0].session_id + "|" + .[0].commit_sha')" "synthesizer|codex|s1|abc1234"
  eq "capture: the default engine is claude and the default category uncategorised" "$(jqv "$recs" '.[1].engine + "|" + .[1].category')" "claude|uncategorised"

  # line-per-record input on stdin, sent through a stub recording command
  cat >"$W/rec.sh" <<'EOS'
#!/bin/bash
cat >"$REC_OUT"
echo "args: $*" >"$REC_OUT.args"
[ -z "${REC_FAIL:-}" ] || { echo "ledger down" >&2; exit 1; }
EOS
  chmod +x "$W/rec.sh"
  export REC_OUT="$W/received.jsonl"
  printf '{"finding":"one","must_fix":true}\n{"finding":"two","pre_existing":true}\n{"finding":"three"}\n' |
    MNEMOSYNE_RECORD_CMD="$W/rec.sh" bash "$C" --session s2 >"$W/out.json"; rc=$?
  eq "capture: records are sent to the recording command" "$rc:$(jqv "$(cat "$W/out.json")" '.status + ":" + (.captured | tostring) + ":" + (.skipped_pre_existing | tostring)')" "0:recorded:2:1"
  eq "capture: the batch arrives on stdin with --batch -" "$(grep -c . "$REC_OUT"):$(cat "$REC_OUT.args")" "2:args: --batch -"
  printf '{"finding":"one"}\n' | REC_FAIL=1 MNEMOSYNE_RECORD_CMD="$W/rec.sh" bash "$C" --session s3 >"$W/out.json"; rc=$?
  eq "capture: a failing ledger is reported but never blocks (exit 0)" "$rc:$(jqv "$(cat "$W/out.json")" .status)" "0:failed"
  has "capture: the failure reason is carried" "$(jqv "$(cat "$W/out.json")" .reason)" "ledger down"
  printf '{"finding":"one"}\n' | env -u DATABASE_URL -u MNEMOSYNE_RECORD_CMD bash "$C" --session s4 >"$W/out.json"; rc=$?
  eq "capture: no DATABASE_URL is skipped, exit 0" "$rc:$(jqv "$(cat "$W/out.json")" .status)" "0:skipped"
  printf '[]' | MNEMOSYNE_RECORD_CMD="$W/rec.sh" bash "$C" --session s5 >"$W/out.json"
  eq "capture: nothing to record is skipped" "$(jqv "$(cat "$W/out.json")" .status)" skipped
  printf 'not json' | MNEMOSYNE_RECORD_CMD="$W/rec.sh" bash "$C" --session s6 >"$W/out.json"; rc=$?
  eq "capture: unreadable input is reported, exit 0" "$rc:$(jqv "$(cat "$W/out.json")" .status)" "0:failed"
  bash "$C" >/dev/null 2>&1; rc=$?
  eq "capture: --session is required (exit 2)" "$rc" 2
  unset REC_OUT
}

# ===================================================================== sections
# SECTIONS-BEGIN
suite_run_ci
suite_dep_audit
suite_stale_ref
suite_tech_debt
suite_endpoints
suite_copywrite
suite_blind
suite_seam
suite_promote
suite_poll
suite_close_run
suite_capture
# SECTIONS-END

PATH="$ORIG_PATH"
if [ "$FAILS" -gt 0 ]; then echo "$FAILS case(s) failed"; exit 1; fi
