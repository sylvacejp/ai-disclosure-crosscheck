#!/usr/bin/env node
'use strict';

// tests/run.js — scenario-based tests for ai-disclosure-crosscheck.
//
// This is a black-box test harness driving the real bash scanner
// (scripts/scan.sh) and the Node CLI wrapper (bin/cli.js) as subprocesses,
// asserting on stdout/stderr/exit code. It intentionally does not use a
// bash statement-coverage tool (kcov/bashcov): the spec (section 3-5)
// requires the core scanner to depend on nothing beyond bash/grep/find,
// and pulling in a coverage tool as a *test-only* dependency would still
// mean every future contributor needs it installed to run `npm test`.
// Coverage here means "each branch of the spec's PASS/WARN/FAIL matrix
// (section 2-3), each suppression grammar form (section 3-4), and each
// CLI/exit-code contract point (section 3-3) has at least one asserting
// scenario" — see the self-review in the handback report for the honest
// caveat this implies.

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const assert = require('assert/strict');

const ROOT = path.resolve(__dirname, '..');
const SCAN = path.join(ROOT, 'scripts', 'scan.sh');
const CLI = path.join(ROOT, 'bin', 'cli.js');
const FIX = path.join(ROOT, 'tests', 'fixtures');

let pass = 0;
let fail = 0;
const failures = [];

function test(name, fn) {
  try {
    fn();
    pass += 1;
    process.stdout.write(`ok   - ${name}\n`);
  } catch (err) {
    fail += 1;
    failures.push({ name, err });
    process.stdout.write(`FAIL - ${name}\n      ${err.message}\n`);
  }
}

// runScan(args, opts) -> { stdout, stderr, status }
function runScan(args, opts = {}) {
  const res = spawnSync('bash', [SCAN, ...args], {
    encoding: 'utf8',
    cwd: opts.cwd || ROOT,
    env: opts.env || process.env,
  });
  return { stdout: res.stdout, stderr: res.stderr, status: res.status };
}

function runCli(args, opts = {}) {
  const res = spawnSync('node', [CLI, ...args], {
    encoding: 'utf8',
    cwd: opts.cwd || ROOT,
  });
  return { stdout: res.stdout, stderr: res.stderr, status: res.status };
}

// writePrecheckIgnore(dir, lines) -> path. Writes a .precheck-ignore into
// `dir` (a temp cwd we pass as scan.sh's cwd, since scan.sh always reads
// "./.precheck-ignore" relative to cwd — see load_precheck_ignore(".")).
function withTempCwd(fn) {
  const dir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'adc-test-'));
  try {
    return fn(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// 1. No signal A at all: rule must not fire (spec table row 1).
// ---------------------------------------------------------------------------
test('signal A absent: text output is an INFO note, exit 0', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-empty'),
    '--server-dir', path.join(FIX, 'server-empty'),
  ]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^INFO: no AI provider call pattern detected/);
});

test('signal A absent: json output has no findings, verdict PASS', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-empty'),
    '--server-dir', path.join(FIX, 'server-empty'),
    '--format', 'json',
  ]);
  assert.equal(r.status, 0);
  const body = JSON.parse(r.stdout);
  assert.deepEqual(body.findings, []);
  assert.equal(body.verdict, 'PASS');
  assert.equal(body.summary.fail, 0);
  assert.equal(body.summary.warn, 0);
});

// ---------------------------------------------------------------------------
// 2. Signal A + signal B (client discloses) -> PASS.
// ---------------------------------------------------------------------------
test('signal A + client discloses provider name: PASS, exit 0', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-disclosed'),
    '--server-dir', path.join(FIX, 'server-openai'),
  ]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^PASS: cross-repo-ai-consent-mismatch/);
  assert.match(r.stdout, /client evidence:/);
});

test('signal A + client discloses via .xcstrings only: PASS', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-xcstrings'),
    '--server-dir', path.join(FIX, 'server-openai'),
    '--format', 'json',
  ]);
  assert.equal(r.status, 0);
  const body = JSON.parse(r.stdout);
  assert.equal(body.findings[0].severity, 'pass');
  assert.equal(body.findings[0].evidence.client_ui_disclosure.file.endsWith('Localizable.xcstrings'), true);
});

// ---------------------------------------------------------------------------
// 3. Signal A + no B + policy discloses -> WARN (N14's flagship new case).
// ---------------------------------------------------------------------------
test('signal A + no client disclosure + policy discloses: WARN, exit 0 by default', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-empty'),
    '--server-dir', path.join(FIX, 'server-openai'),
    '--policy-file', path.join(FIX, 'policy-disclosed.html'),
  ]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^WARN: cross-repo-ai-consent-mismatch/);
  assert.match(r.stdout, /policy evidence:/);
});

test('same case with --fail-on warn: exit 1', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-empty'),
    '--server-dir', path.join(FIX, 'server-openai'),
    '--policy-file', path.join(FIX, 'policy-disclosed.html'),
    '--fail-on', 'warn',
  ]);
  assert.equal(r.status, 1);
});

// ---------------------------------------------------------------------------
// 4. Signal A + no B + policy given but silent -> FAIL.
// ---------------------------------------------------------------------------
test('signal A + no client disclosure + policy silent on provider: FAIL, exit 1', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-empty'),
    '--server-dir', path.join(FIX, 'server-openai'),
    '--policy-file', path.join(FIX, 'policy-not-disclosed.html'),
  ]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /^FAIL: cross-repo-ai-consent-mismatch/);
});

// ---------------------------------------------------------------------------
// 5. Signal A + no B + --policy-file omitted -> WARN (simplified).
// ---------------------------------------------------------------------------
test('signal A + no client disclosure + no --policy-file: WARN (simplified), exit 0 by default', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-empty'),
    '--server-dir', path.join(FIX, 'server-openai'),
  ]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^WARN: cross-repo-ai-consent-mismatch/);
  assert.match(r.stdout, /Re-run with --policy-file/);
});

// ---------------------------------------------------------------------------
// 6/7. Suppression grammar (.precheck-ignore): rule-wide and rule+path.
// ---------------------------------------------------------------------------
test('.precheck-ignore rule-wide suppression: suppressed=true, exit 0 even with --fail-on warn', () => {
  withTempCwd((dir) => {
    fs.writeFileSync(path.join(dir, '.precheck-ignore'), 'cross-repo-ai-consent-mismatch\n');
    const r = runScan([
      '--client-dir', path.join(FIX, 'client-empty'),
      '--server-dir', path.join(FIX, 'server-openai'),
      '--policy-file', path.join(FIX, 'policy-not-disclosed.html'),
      '--fail-on', 'warn',
    ], { cwd: dir });
    assert.equal(r.status, 0);
    assert.match(r.stdout, /suppressed via \.precheck-ignore/);
  });
});

test('.precheck-ignore rule+path-glob suppression matches by server evidence path', () => {
  withTempCwd((dir) => {
    fs.writeFileSync(
      path.join(dir, '.precheck-ignore'),
      'cross-repo-ai-consent-mismatch tests/fixtures/server-openai\n'
    );
    const r = runScan([
      '--client-dir', path.join(FIX, 'client-empty'),
      '--server-dir', path.join(FIX, 'server-openai'),
      '--fail-on', 'warn',
    ], { cwd: dir });
    // path-glob in the ignore file is matched against AI_SIG_FILE as given
    // on the command line, so pass the same relative form used above.
    assert.equal(r.status, 0);
    assert.match(r.stdout, /suppressed via \.precheck-ignore/);
  });
});

test('.precheck-ignore rule+path-glob for a DIFFERENT path does not suppress', () => {
  withTempCwd((dir) => {
    fs.writeFileSync(
      path.join(dir, '.precheck-ignore'),
      'cross-repo-ai-consent-mismatch some/unrelated/path\n'
    );
    const r = runScan([
      '--client-dir', path.join(FIX, 'client-empty'),
      '--server-dir', path.join(FIX, 'server-openai'),
    ], { cwd: dir });
    assert.equal(r.status, 0); // default --fail-on fail, and this is a WARN
    // The SUMMARY line always prints a "suppressed=N" counter (N=0 here), so
    // check for the specific "(suppressed via .precheck-ignore)" annotation
    // rather than the bare word "suppressed".
    assert.doesNotMatch(r.stdout, /suppressed via \.precheck-ignore/);
    assert.match(r.stdout, /SUMMARY: fail=0 warn=1 pass=0 suppressed=0/);
    assert.match(r.stdout, /^WARN:/);
  });
});

// ---------------------------------------------------------------------------
// 8. Bare path-glob exclusion: excludes a path from scanning entirely.
// ---------------------------------------------------------------------------
test('without .precheck-ignore, the vendor/ OpenAI call under server-excluded is picked up', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-empty'),
    '--server-dir', path.join(FIX, 'server-excluded'),
    '--format', 'json',
  ]);
  const body = JSON.parse(r.stdout);
  assert.equal(body.findings[0].provider, 'OpenAI');
  assert.match(body.findings[0].evidence.server_ai_call.file, /vendor\/openaiWrapper\.js$/);
});

test('bare path-glob "vendor" in .precheck-ignore excludes it; Anthropic call under real/ is found instead', () => {
  withTempCwd((dir) => {
    fs.writeFileSync(path.join(dir, '.precheck-ignore'), 'vendor\n');
    const r = runScan([
      '--client-dir', path.join(FIX, 'client-empty'),
      '--server-dir', path.join(FIX, 'server-excluded'),
      '--format', 'json',
    ], { cwd: dir });
    const body = JSON.parse(r.stdout);
    assert.equal(body.findings[0].provider, 'Anthropic');
    assert.match(body.findings[0].evidence.server_ai_call.file, /real\/anthropicClient\.js$/);
  });
});

// ---------------------------------------------------------------------------
// 9. --config fills in missing CLI args (spec 3-1).
// ---------------------------------------------------------------------------
test('--config supplies clientDir/serverDir/policyFile when CLI omits them', () => {
  const r = runScan(['--config', path.join('tests', 'fixtures', 'config-sample.json')], { cwd: ROOT });
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^PASS: cross-repo-ai-consent-mismatch/);
});

test('CLI-supplied --server-dir overrides --config value', () => {
  const r = runScan([
    '--config', path.join('tests', 'fixtures', 'config-sample.json'),
    '--server-dir', path.join(FIX, 'server-empty'),
  ], { cwd: ROOT, });
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^INFO: no AI provider call pattern detected/);
});

// ---------------------------------------------------------------------------
// 10-12. Bad usage / environment error exit codes (spec 3-3).
// ---------------------------------------------------------------------------
test('missing --client-dir: exit 64', () => {
  const r = runScan(['--server-dir', path.join(FIX, 'server-openai')]);
  assert.equal(r.status, 64);
  assert.match(r.stderr, /--client-dir is required/);
});

test('missing --server-dir: exit 64', () => {
  const r = runScan(['--client-dir', path.join(FIX, 'client-empty')]);
  assert.equal(r.status, 64);
  assert.match(r.stderr, /--server-dir is required/);
});

test('--client-dir pointing at a non-directory: exit 64', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'policy-disclosed.html'),
    '--server-dir', path.join(FIX, 'server-openai'),
  ]);
  assert.equal(r.status, 64);
  assert.match(r.stderr, /not a directory/);
});

test('--policy-file pointing at a missing file: exit 64', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-empty'),
    '--server-dir', path.join(FIX, 'server-openai'),
    '--policy-file', path.join(FIX, 'does-not-exist.html'),
  ]);
  assert.equal(r.status, 64);
  assert.match(r.stderr, /not a file/);
});

test('unknown option: exit 64', () => {
  const r = runScan(['--nope', 'x']);
  assert.equal(r.status, 64);
  assert.match(r.stderr, /unknown option/);
});

test('invalid --format value: exit 64', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-empty'),
    '--server-dir', path.join(FIX, 'server-openai'),
    '--format', 'yaml',
  ]);
  assert.equal(r.status, 64);
});

test('invalid --fail-on value: exit 64', () => {
  const r = runScan([
    '--client-dir', path.join(FIX, 'client-empty'),
    '--server-dir', path.join(FIX, 'server-openai'),
    '--fail-on', 'nope',
  ]);
  assert.equal(r.status, 64);
});

test('-h/--help and -v/--version exit 0', () => {
  const h = runScan(['--help']);
  assert.equal(h.status, 0);
  assert.match(h.stdout, /Usage:/);
  const v = runScan(['--version']);
  assert.equal(v.status, 0);
  assert.match(v.stdout, /^\d+\.\d+\.\d+/);
});

// ---------------------------------------------------------------------------
// 13. bin/cli.js Node wrapper: delegates to scan.sh, propagates exit code.
// ---------------------------------------------------------------------------
test('cli.js --help prints usage and exits 0 without needing --client-dir/--server-dir', () => {
  const r = runCli(['--help']);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /ai-disclosure-crosscheck/);
});

test('cli.js --version exits 0 and prints the package version', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
  const r = runCli(['--version']);
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), pkg.version);
});

test('cli.js propagates scan.sh exit 64 on bad usage', () => {
  const r = runCli(['--client-dir', path.join(FIX, 'client-empty')]);
  assert.equal(r.status, 64);
});

test('cli.js propagates scan.sh exit 1 (FAIL) through to the wrapper', () => {
  const r = runCli([
    '--client-dir', path.join(FIX, 'client-empty'),
    '--server-dir', path.join(FIX, 'server-openai'),
    '--policy-file', path.join(FIX, 'policy-not-disclosed.html'),
  ]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /^FAIL:/);
});

test('cli.js exits 70 if the bundled scan.sh is missing from the package', () => {
  // Simulates a broken/incomplete npm install (spec 3-3: exit 70 =
  // environment error). Copies just bin/cli.js + package.json into an
  // isolated temp dir with no scripts/ directory alongside it, so
  // fs.existsSync(SCAN) in cli.js is false.
  withTempCwd((dir) => {
    fs.mkdirSync(path.join(dir, 'bin'));
    fs.copyFileSync(CLI, path.join(dir, 'bin', 'cli.js'));
    fs.copyFileSync(path.join(ROOT, 'package.json'), path.join(dir, 'package.json'));
    const res = spawnSync('node', [path.join(dir, 'bin', 'cli.js'), '--client-dir', '.', '--server-dir', '.'], {
      encoding: 'utf8',
    });
    assert.equal(res.status, 70);
    assert.match(res.stderr, /bundled scan\.sh is missing/);
  });
});

test('cli.js propagates scan.sh exit 0 (PASS) through the wrapper', () => {
  const r = runCli([
    '--client-dir', path.join(FIX, 'client-disclosed'),
    '--server-dir', path.join(FIX, 'server-openai'),
  ]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^PASS:/);
});

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------
process.stdout.write(`\n${pass} passed, ${fail} failed\n`);
if (fail > 0) {
  process.exitCode = 1;
}
