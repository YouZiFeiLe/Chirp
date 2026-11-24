import test from 'node:test';
import assert from 'node:assert/strict';
import { isValidClientVersionPolicy } from './client-version.js';

const policy = (latestVersion, latestBuild, minimumVersion, minimumBuild) => ({
  latest_version: latestVersion, latest_build: latestBuild,
  minimum_version: minimumVersion, minimum_build: minimumBuild,
});

test('a newer version permits resetting the latest build below the minimum build', () => {
  assert.equal(isValidClientVersionPolicy(policy('0.11.1', 1, '0.11.0', 25)), true);
  assert.equal(isValidClientVersionPolicy(policy('0.10.0', 1, '0.9.999999', 2147483647)), true);
  assert.equal(isValidClientVersionPolicy(policy('1.0.0', 1, '0.999999.999999', 2147483647)), true);
});

test('the full minimum pair must not exceed the latest pair', () => {
  assert.equal(isValidClientVersionPolicy(policy('0.11.1', 1, '0.11.1', 1)), true);
  assert.equal(isValidClientVersionPolicy(policy('0.11.1', 2, '0.11.1', 1)), true);
  assert.equal(isValidClientVersionPolicy(policy('0.11.1', 1, '0.11.1', 2)), false);
  assert.equal(isValidClientVersionPolicy(policy('0.11.1', 99, '0.11.2', 1)), false);
  assert.equal(isValidClientVersionPolicy(policy('0.9.0', 99, '0.10.0', 1)), false);
});

test('minimum versions and both builds require canonical bounded values', () => {
  for (const version of [undefined, '', '0.11', '00.11.0', '0.11.0\n', '0.11.0-beta', '1000000.0.0']) {
    assert.equal(isValidClientVersionPolicy(policy('0.11.1', 1, version, 1)), false);
    assert.equal(isValidClientVersionPolicy(policy(version, 1, '0.11.0', 1)), false);
  }
  for (const build of [undefined, 0, -1, 1.5, 2147483648, '1', NaN, Infinity]) {
    assert.equal(isValidClientVersionPolicy(policy('0.11.1', 1, '0.11.0', build)), false);
    assert.equal(isValidClientVersionPolicy(policy('0.11.1', build, '0.11.0', 1)), false);
  }
});
