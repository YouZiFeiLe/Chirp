import zhCN from './locales/zh-CN.js';
import en from './locales/en.js';

export const DEFAULT_LOCALE = 'zh-CN';
export const FALLBACK_LOCALE = 'en';
export const STORAGE_KEY = 'chirp.language';
export const dictionaries = { 'zh-CN': zhCN, en };
const choices = new Set(['auto', ...Object.keys(dictionaries)]);
const bindings = new Map();
let locale = DEFAULT_LOCALE;
let preference = 'auto';
let host;

// Match scripts as well as languages: Traditional Chinese is not a Simplified
// Chinese translation. Consult every browser preference before falling back.
export function resolveLocale(languages = [], choice = 'auto') {
  if (Object.hasOwn(dictionaries, choice)) return choice;
  if (!languages.length) return DEFAULT_LOCALE;
  for (const language of languages) {
    try {
      const tag = new Intl.Locale(language).maximize();
      if (tag.language === 'en') return 'en';
      if (tag.language === 'zh' && tag.script === 'Hans') return 'zh-CN';
    } catch { /* Ignore malformed language tags. */ }
  }
  return FALLBACK_LOCALE;
}

export const getLocale = () => locale;
export const getPreference = () => preference;

export function t(key, params = {}) {
  if (key && typeof key === 'object') return t(key.key, key.params);
  const template = dictionaries[locale][key] ?? dictionaries[FALLBACK_LOCALE][key] ?? key ?? '';
  return template.replace(/\{(\w+)\}/g, (token, name) => {
    const value = params?.[name];
    return value === undefined ? token : String(value && typeof value === 'object' && value.key ? t(value) : value);
  });
}

function renderText(element, key, params) {
  const text = t(key, params);
  const slots = new Map([...element.querySelectorAll('[data-i18n-slot]')].map((node) => [node.dataset.i18nSlot, node]));
  if (!slots.size) { element.textContent = text; return; }
  // Preserve explicit DOM slots (for example a member's name) without treating
  // translations or interpolated user input as HTML.
  element.replaceChildren(...text.split(/(\{\w+\})/g).map((part) => /^\{\w+\}$/.test(part) ? slots.get(part.slice(1, -1)) ?? part : part));
}

export function setText(element, key, params = {}) {
  if (typeof element === 'string') element = host.document.querySelector(element);
  if (key && typeof key === 'object') { params = key.params ?? {}; key = key.key; }
  bindings.set(element, { key, params });
  renderText(element, key, params);
}

export const textBinding = (element) => bindings.get(element) ?? { key: element.dataset.i18n, params: {} };

export function translatePage() {
  const document = host.document;
  document.documentElement.lang = locale;
  document.querySelectorAll('[data-i18n]').forEach((element) => {
    if (!bindings.has(element)) renderText(element, element.dataset.i18n);
  });
  document.querySelectorAll('[data-i18n-attrs]').forEach((element) => {
    for (const entry of element.dataset.i18nAttrs.split(';')) {
      const [attribute, key] = entry.split(':');
      element.setAttribute(attribute, t(key));
    }
  });
  for (const [element, binding] of bindings) {
    if (!element.isConnected) bindings.delete(element);
    else renderText(element, binding.key, binding.params);
  }
  document.querySelectorAll('[data-language-select]').forEach((select) => { select.value = preference; });
  document.querySelectorAll('[data-i18n-validation]').forEach((input) => {
    if (input.validity.customError) input.setCustomValidity(t(input.dataset.i18nValidation));
  });
}

function browserLanguages() {
  const navigator = host.navigator;
  return navigator.languages?.length ? navigator.languages : navigator.language ? [navigator.language] : [];
}

export function setLanguage(choice, persist = true) {
  preference = choices.has(choice) ? choice : 'auto';
  locale = resolveLocale(browserLanguages(), preference);
  if (persist) {
    try { host.localStorage.setItem(STORAGE_KEY, preference); } catch { /* Storage may be disabled. */ }
  }
  translatePage();
  host.dispatchEvent(new host.CustomEvent('chirp:languagechange', { detail: { locale, preference } }));
}

export function initI18n(window = globalThis.window) {
  host = window;
  let saved;
  try { saved = host.localStorage.getItem(STORAGE_KEY); } catch { /* Continue with browser preferences. */ }
  setLanguage(saved, false);
  host.document.querySelectorAll('[data-language-select]').forEach((select) => {
    select.addEventListener('change', () => setLanguage(select.value));
  });
  host.document.querySelectorAll('[data-i18n-validation]').forEach((input) => {
    input.addEventListener('invalid', () => input.setCustomValidity(t(input.dataset.i18nValidation)));
    input.addEventListener('input', () => input.setCustomValidity(''));
  });
  host.addEventListener('languagechange', () => { if (preference === 'auto') setLanguage('auto', false); });
  host.addEventListener('storage', (event) => {
    if (event.key === STORAGE_KEY || event.key === null) setLanguage(event.newValue, false);
  });
}

export class LocalizedError extends Error {
  constructor(key, params = {}, code) {
    super(t(key, params));
    this.key = key;
    this.params = params;
    this.code = code;
  }
}

export function apiError(error, path, status) {
  const code = error?.code;
  let key = `errors.${code}`;
  if (code === 'INVALID_NAME') key = /^\/rooms\/[^/]+$/.test(path) ? 'errors.roomName' : 'errors.memberName';
  if (code === 'PASSKEY_INVALID') key = path.includes('/register/') ? 'errors.passkeyRegister' : status === 403 ? 'errors.passkeyVerify' : 'errors.passkeyLogin';
  if (!Object.hasOwn(en, key)) key = 'errors.request';
  return new LocalizedError(key, { status }, code);
}

export function friendlyError(error) {
  if (error instanceof LocalizedError) return error;
  if (error.name === 'NotAllowedError' || error.name === 'AbortError') return new LocalizedError('passkey.errors.cancelled');
  if (error.name === 'InvalidStateError') return new LocalizedError('passkey.errors.exists');
  if (error.name === 'SecurityError') return new LocalizedError('passkey.errors.security');
  if (error.name === 'TimeoutError' || error instanceof TypeError) return new LocalizedError('errors.network');
  return new LocalizedError('errors.operation');
}
