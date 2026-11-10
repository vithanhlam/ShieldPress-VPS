#!/usr/bin/env node
'use strict';
// Read deployment metadata as JSON; never execute application configuration.
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');

try {
  const root = process.argv[2];
  const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  const requirement = pkg.engines && pkg.engines.node;
  if (requirement) {
    const npmRequire = createRequire(fs.realpathSync(process.argv[3]));
    const semver = npmRequire('semver');
    if (typeof requirement !== 'string' || !semver.validRange(requirement)) {
      throw new Error('Invalid engines.node requirement in package.json.');
    }
    if (!semver.satisfies(process.versions.node, requirement)) {
      throw new Error(`Project requires Node.js ${requirement}; current runtime is ${process.version}. Select a compatible runtime before deployment. The shared server runtime was not changed.`);
    }
  }
  const exists = name => fs.existsSync(path.join(root, name));
  const scripts = Object.values(pkg.scripts || {}).join('\n');
  const usesPnpm = exists('pnpm-lock.yaml') || exists('pnpm-workspace.yaml') || /\bpnpm\b/.test(scripts);
  let manager = 'npm', version = '';
  if (pkg.packageManager) {
    const pin = /^(npm|pnpm)@(\d+\.\d+\.\d+)(?:\+sha(?:224|256|384|512)\.[a-fA-F0-9]+)?$/.exec(pkg.packageManager);
    if (!pin) throw new Error('Unsupported packageManager. Use an exact npm@x.y.z or pnpm@x.y.z version.');
    manager = pin[1];
    version = pin[2];
    if (manager === 'npm' && usesPnpm) throw new Error('packageManager selects npm but this project uses pnpm. Correct its package manager metadata before deployment.');
  } else if (usesPnpm) {
    manager = 'pnpm';
  } else if (exists('yarn.lock') || exists('bun.lock') || exists('bun.lockb')) {
    throw new Error('This deployment supports npm and pnpm. Configure the project package manager explicitly before deployment.');
  }
  process.stdout.write(`${manager}\n${version}\n`);
} catch (error) {
  console.error(`[ERROR] ${error.message}`);
  process.exitCode = 1;
}
