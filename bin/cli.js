#!/usr/bin/env node
'use strict';

// ai-disclosure-crosscheck CLI: a thin Node wrapper so the scanner runs via
// `npx ai-disclosure-crosscheck`, following the same shape as
// appstore-precheck's bin/cli.js (spec section 3-5: the Node CLI is a
// distribution convenience; scan.sh — bash/grep/find only — is the single
// source of truth for the detection logic. Nothing here re-implements a
// check).

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const PKG_ROOT = path.resolve(__dirname, '..');
const SCAN = path.join(PKG_ROOT, 'scripts', 'scan.sh');

function pkgVersion() {
  try {
    return JSON.parse(fs.readFileSync(path.join(PKG_ROOT, 'package.json'), 'utf8')).version;
  } catch (_) {
    return 'unknown';
  }
}

function printHelp() {
  process.stdout.write(
    `ai-disclosure-crosscheck ${pkgVersion()} - cross-repo AI disclosure linter\n` +
    `\n` +
    `Usage:\n` +
    `  npx ai-disclosure-crosscheck --client-dir <path> --server-dir <path> \\\n` +
    `      [--policy-file <path>] [--format text|json] [--fail-on warn|fail]\n` +
    `\n` +
    `Read-only. Checks whether AI provider disclosure exists somewhere\n` +
    `(client UI or public policy) for an AI API call found in --server-dir.\n` +
    `\n` +
    `Options:\n` +
    `  --client-dir <path>   Client/UI source directory (required, or via config)\n` +
    `  --server-dir <path>   Server source directory (required, or via config)\n` +
    `  --policy-file <path>  Public privacy-policy document, optional\n` +
    `  --format <fmt>        text (default) or json\n` +
    `  --fail-on <level>     warn or fail (default: fail)\n` +
    `  --config <path>       .ai-disclosure-crosscheck.json (default: auto-detected in cwd)\n` +
    `  -v, --version          Print the version and exit\n` +
    `  -h, --help             Show this help and exit\n` +
    `\n` +
    `Exit codes: 0 ok, 1 verdict at or past --fail-on, 64 bad usage,\n` +
    `70 environment error (bash or the bundled scanner missing).\n` +
    `\n` +
    `Requires bash, grep, and find on PATH. No credentials, no network.\n`
  );
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.includes('-h') || argv.includes('--help')) { printHelp(); process.exit(0); }
  if (argv.includes('-v') || argv.includes('--version')) {
    process.stdout.write(pkgVersion() + '\n');
    process.exit(0);
  }

  if (!fs.existsSync(SCAN)) {
    process.stderr.write('ai-disclosure-crosscheck: bundled scan.sh is missing from the package\n');
    process.exit(70);
  }

  const result = spawnSync('bash', [SCAN, ...argv], {
    stdio: 'inherit',
    maxBuffer: 32 * 1024 * 1024,
  });

  if (result.error && result.error.code === 'ENOENT') {
    process.stderr.write(
      'ai-disclosure-crosscheck: bash is required to run the scanner ' +
      '(install bash, or use WSL / Git Bash on Windows)\n'
    );
    process.exit(70);
  }
  if (result.error) {
    process.stderr.write(`ai-disclosure-crosscheck: failed to run the scanner: ${result.error.message}\n`);
    process.exit(70);
  }
  if (result.signal) {
    process.stderr.write(`ai-disclosure-crosscheck: scanner was killed by signal ${result.signal}\n`);
    process.exit(70);
  }
  process.exit(result.status === null ? 70 : result.status);
}

main();
