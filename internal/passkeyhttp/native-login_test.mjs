import assert from 'node:assert/strict';
import test from 'node:test';
import { setImmediate } from 'node:timers/promises';
import { nativeLoginCallback, waitForWindowsHandoff } from './web/native-login.js';

const code = 'a'.repeat(43);
const state = 's'.repeat(43);
const apple = 'cn.youzifeile.chirp://auth/callback';
const windows = 'cn.youzifeile.chirp.windows://auth/callback';
const query = `?code=${code}&state=${state}`;

test('accepts a one-time callback for the requesting native app', () => {
  for (const [client_id, redirect_uri] of [['chirp-apple', apple], ['chirp-windows', windows], ['chirp-android', 'cn.youzifeile.chirp.android://auth/callback']]) {
    const callback = redirect_uri + query;
    assert.equal(nativeLoginCallback({client_id, redirect_uri, state}, callback), callback);
  }
});

test('rejects cross-client, ambiguous and mismatched callbacks', () => {
  const request = {client_id: 'chirp-windows', redirect_uri: windows, state};
  for (const callback of [
    apple + query, windows + query + '#', windows + query + '&code=' + code,
    windows + query.replace(state, code), windows.replace('://auth', '://user@auth') + query,
    windows.replace('://auth', '://auth:443') + query, 'https://example.test/' + query,
  ]) {
    assert.equal(nativeLoginCallback(request, callback), null);
  }
  assert.equal(nativeLoginCallback({...request, redirect_uri: apple}, windows + query), null);
});

test('waits through pending status and network errors for a Windows receipt', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'] });
  let calls = 0;
  const received = waitForWindowsHandoff(async () => {
    calls++;
    if (calls === 2) throw new TypeError('offline');
    return { received: calls === 3 };
  });
  for (let i = 0; i < 3; i++) {
    t.mock.timers.tick(4000);
    await setImmediate();
  }
  assert.equal(await received, true);
  assert.equal(calls, 3);
});

test('leaves the page open when the Windows code expires or the status check times out', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'] });
  const expired = waitForWindowsHandoff(async () => { throw Object.assign(new Error(), { code: 'INVALID_AUTHORIZATION' }); });
  t.mock.timers.tick(1000);
  assert.equal(await expired, false);

  const pending = waitForWindowsHandoff(async () => ({ received: false }));
  t.mock.timers.tick(60_000);
  assert.equal(await pending, false);
});
