import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolveLocale, initI18n, getLocale, getPreference, setLanguage, t, setText, textBinding, apiError, friendlyError, LocalizedError, dictionaries, STORAGE_KEY } from './i18n.js';

const root = new URL('../../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');

function windowFor(languages, { saved, blocked = false } = {}) {
  const window = new EventTarget();
  const storage = new Map(saved === undefined ? [] : [[STORAGE_KEY, saved]]);
  Object.assign(window, {
    navigator: { languages }, CustomEvent,
    document: { documentElement: {}, querySelectorAll: () => [] },
    localStorage: {
      getItem(key) { if (blocked) throw new Error('Storage disabled'); return storage.get(key) ?? null; },
      setItem(key, value) { if (blocked) throw new Error('Storage disabled'); storage.set(key, value); },
    },
  });
  return window;
}

test('browser preferences distinguish default, matching, and unsupported-language fallback', () => {
  for (const [languages, expected] of [
    [[], 'zh-CN'], [['zh-CN'], 'zh-CN'], [['zh'], 'zh-CN'], [['zh-SG'], 'zh-CN'],
    [['zh-Hans'], 'zh-CN'], [['zh-Hans-HK'], 'zh-CN'], [['en-US'], 'en'], [['en-GB'], 'en'],
    [['fr-FR', 'zh-CN', 'en'], 'zh-CN'], [['fr-FR', 'en', 'zh-CN'], 'en'],
    [['ja-JP'], 'en'], [['zh-TW'], 'en'], [['zh-Hant-CN'], 'en'], [['invalid_tag', 'zh-CN'], 'zh-CN'],
  ]) assert.equal(resolveLocale(languages), expected, JSON.stringify(languages));
  assert.equal(resolveLocale(['en'], 'zh-CN'), 'zh-CN');
  assert.equal(resolveLocale(['zh-CN'], 'en'), 'en');
  assert.equal(resolveLocale(['en'], 'corrupt-preference'), 'en');
});

test('manual selection persists, overrides browser changes, and can return to automatic', () => {
  const window = windowFor(['zh-CN']);
  initI18n(window);
  assert.equal(getLocale(), 'zh-CN');
  setLanguage('en');
  assert.equal(window.localStorage.getItem(STORAGE_KEY), 'en');
  window.dispatchEvent(new Event('languagechange'));
  assert.equal(getLocale(), 'en');
  initI18n(windowFor(['zh-CN'], { saved: 'en' }));
  assert.equal(getLocale(), 'en');
  setLanguage('auto');
  assert.equal(getLocale(), 'zh-CN');
  assert.equal(getPreference(), 'auto');
});

test('automatic preferences update across browser changes and same-origin tabs', () => {
  const window = windowFor(['en']);
  initI18n(window);
  window.navigator.languages = ['zh-CN'];
  window.dispatchEvent(new Event('languagechange'));
  assert.equal(getLocale(), 'zh-CN');
  window.dispatchEvent(Object.assign(new Event('storage'), { key: STORAGE_KEY, newValue: 'en' }));
  assert.equal(getLocale(), 'en');
  window.dispatchEvent(Object.assign(new Event('storage'), { key: STORAGE_KEY, newValue: 'auto' }));
  assert.equal(getLocale(), 'zh-CN');
});

test('blocked storage and invalid saved choices do not prevent language selection', () => {
  initI18n(windowFor(['ja'], { blocked: true }));
  assert.equal(getLocale(), 'en');
  assert.doesNotThrow(() => setLanguage('zh-CN'));
  assert.equal(getLocale(), 'zh-CN');
  initI18n(windowFor([], { saved: 'invalid' }));
  assert.equal(getLocale(), 'zh-CN');
});

test('dynamic messages and saved button labels can be translated without resetting state', () => {
  const element = { isConnected: true, dataset: { i18n: 'common.confirm' }, querySelectorAll: () => [], textContent: '' };
  initI18n(windowFor(['zh-CN']));
  setText(element, 'admin.confirm.deleteMember', { name: '<Alice & Bob>' });
  const original = textBinding(element);
  assert.equal(element.textContent, '删除 <Alice & Bob>？');
  setText(element, 'common.processing');
  setLanguage('en');
  assert.equal(element.textContent, 'Working…');
  setText(element, original);
  assert.equal(element.textContent, 'Delete <Alice & Bob>?');
  setText(element, 'admin.errors.stale', { message: new LocalizedError('errors.timeout') });
  setLanguage('zh-CN');
  assert.equal(element.textContent, '请求超时，请稍后重试 当前显示上次同步的数据。');
  element.isConnected = false;
});

test('locale dictionaries have matching nonempty keys and interpolation parameters', () => {
  assert.deepEqual(Object.keys(dictionaries['zh-CN']).sort(), Object.keys(dictionaries.en).sort());
  for (const [key, english] of Object.entries(dictionaries.en)) {
    const chinese = dictionaries['zh-CN'][key];
    assert.ok(english.trim() && chinese.trim(), key);
    assert.deepEqual([...chinese.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort(), [...english.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort(), key);
    assert.doesNotMatch(english, /[\p{Script=Han}]/u, key);
  }
  initI18n(windowFor(['zh-CN']));
  const original = dictionaries['zh-CN']['common.language'];
  try {
    delete dictionaries['zh-CN']['common.language'];
    assert.equal(t('common.language'), 'Language');
  } finally { dictionaries['zh-CN']['common.language'] = original; }
});

test('every page and script translation reference exists in both dictionaries', () => {
  const pages = ['adminhttp/web/index.html', 'passkeyhttp/web/index.html', 'passkeyhttp/web/register.html', 'passkeyhttp/web/device.html'];
  for (const path of pages) {
    const html = read(`internal/${path}`);
    const keys = [...html.matchAll(/data-i18n(?:-validation)?="([^"]+)"/g)].map((m) => m[1]);
    for (const match of html.matchAll(/data-i18n-attrs="([^"]+)"/g)) keys.push(...match[1].split(';').map((entry) => entry.split(':')[1]));
    for (const key of keys) assert.ok(Object.hasOwn(dictionaries.en, key), `${path}: ${key}`);
    assert.match(html, /data-language-select/);
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]);
    assert.equal(new Set(ids).size, ids.length, `Duplicate IDs in ${path}`);
  }
  for (const path of ['adminhttp/web/app.js', 'passkeyhttp/web/app.js', 'webui/i18n.js']) {
    const source = read(`internal/${path}`);
    for (const match of source.matchAll(/'((?:common|admin|passkey|errors)\.[\w.]+)'/g)) assert.ok(Object.hasOwn(dictionaries.en, match[1]), `${path}: ${match[1]}`);
  }
});

test('API error translations preserve codes and disambiguate operation-specific messages', () => {
  initI18n(windowFor(['en']));
  const room = apiError({ code: 'INVALID_NAME', message: '中文后端提示' }, '/rooms/friends', 400);
  const member = apiError({ code: 'INVALID_NAME' }, '/members/alice', 400);
  assert.equal(room.key, 'errors.roomName');
  assert.equal(member.key, 'errors.memberName');
  assert.equal(apiError({ code: 'PASSKEY_INVALID' }, '/api/auth/register/finish', 400).key, 'errors.passkeyRegister');
  assert.equal(apiError({ code: 'PASSKEY_INVALID' }, '/api/auth/login/finish', 400).key, 'errors.passkeyLogin');
  assert.equal(apiError({ code: 'PASSKEY_INVALID' }, '/api/auth/login/finish', 403).key, 'errors.passkeyVerify');
  assert.equal(apiError({ code: 'UNKNOWN' }, '/', 502).message, 'Request failed (502). Refresh and try again.');
  for (const path of ['adminhttp/server.go', 'adminhttp/room_password.go', 'passkeyhttp/server.go', 'passkeyhttp/device_login.go']) {
    for (const match of read(`internal/${path}`).matchAll(/httpresponse\.Error\([^\n]+?, "([A-Z_]+)",/g)) {
      const error = apiError({ code: match[1] }, '/', 400);
      assert.equal(error.code, match[1]);
      assert.notEqual(error.key, 'errors.request', `${path}: ${match[1]}`);
    }
  }
  assert.equal(friendlyError({ name: 'NotAllowedError' }).key, 'passkey.errors.cancelled');
  assert.equal(friendlyError(new TypeError('Network failure')).key, 'errors.network');
});
