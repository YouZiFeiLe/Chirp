import { initI18n, setText, textBinding, LocalizedError, apiError, friendlyError } from '/assets/i18n.js';
import { nativeLoginCallback, waitForWindowsHandoff } from '/assets/native-login.js';

initI18n();

const $ = (selector) => document.querySelector(selector);
const page = document.body.dataset.page;
const loginParameters = new URLSearchParams(window.location.search);
const clientAuthorization = loginParameters.has('client_id') ? Object.fromEntries(['client_id', 'redirect_uri', 'state', 'code_challenge', 'code_challenge_method'].map((key) => [key, loginParameters.get(key) || ''])) : null;
let busy = false;

function message(selector, key = '', params = {}) { setText(selector, key, params); $(selector).hidden = !key; }

async function api(path, body) {
  const response = await fetch(path, { method: body === undefined ? 'GET' : 'POST', headers: body === undefined ? {} : { 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body), credentials: 'same-origin', cache: 'no-store', signal: AbortSignal.timeout(15000) });
  if (response.status === 204) return null;
  const result = await response.json().catch(() => null);
  if (!response.ok) throw apiError(result?.error, path, response.status);
  if (!result) throw new LocalizedError('errors.response');
  return result;
}

function decode(value) { return Uint8Array.from(atob(value.replace(/-/g, '+').replace(/_/g, '/')), (char) => char.charCodeAt(0)).buffer; }
function encode(buffer) { return btoa(String.fromCharCode(...new Uint8Array(buffer))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
function creationOptions(json) {
  if (PublicKeyCredential.parseCreationOptionsFromJSON) return PublicKeyCredential.parseCreationOptionsFromJSON(json);
  return { ...json, challenge: decode(json.challenge), user: { ...json.user, id: decode(json.user.id) }, excludeCredentials: json.excludeCredentials?.map((item) => ({ ...item, id: decode(item.id) })) };
}
function requestOptions(json) {
  if (PublicKeyCredential.parseRequestOptionsFromJSON) return PublicKeyCredential.parseRequestOptionsFromJSON(json);
  return { ...json, challenge: decode(json.challenge), allowCredentials: json.allowCredentials?.map((item) => ({ ...item, id: decode(item.id) })) };
}
function credentialJSON(credential) {
  if (credential.toJSON) return credential.toJSON();
  const response = { clientDataJSON: encode(credential.response.clientDataJSON) };
  if (credential.response.attestationObject) { response.attestationObject = encode(credential.response.attestationObject); response.transports = credential.response.getTransports?.() || []; }
  else { response.authenticatorData = encode(credential.response.authenticatorData); response.signature = encode(credential.response.signature); response.userHandle = credential.response.userHandle ? encode(credential.response.userHandle) : null; }
  return { id: credential.id, rawId: encode(credential.rawId), type: credential.type, authenticatorAttachment: credential.authenticatorAttachment, response, clientExtensionResults: credential.getClientExtensionResults() };
}

async function run(button, action, errorTarget = '#error-message') {
  if (busy) return;
  if (!window.isSecureContext || !window.PublicKeyCredential) { message(errorTarget, 'passkey.errors.unsupported'); $(errorTarget).focus(); return; }
  busy = true; button.disabled = true; button.setAttribute('aria-busy', 'true');
  const label = button.querySelector('[data-i18n]') || button;
  const original = textBinding(label);
  setText(label, 'passkey.confirmPrompt'); message(errorTarget);
  try { await action(); } catch (error) { message(errorTarget, friendlyError(error)); $(errorTarget).focus(); }
  finally { busy = false; button.disabled = false; button.removeAttribute('aria-busy'); setText(label, original); }
}

function signedIn(member) {
  $('#login-panel').hidden = true;
  $('#signed-in-panel').hidden = false;
  $('#signed-in-name').textContent = member.display_name;
  $('#admin-link').hidden = !member.is_admin;
  $('#signed-in-panel').focus();
  if (loginParameters.get('admin') === '1') {
    if (member.is_admin) window.location.replace('/admin/');
    else message('#logout-error', 'errors.ADMIN_REQUIRED');
  }
}

async function returnToWindows(callback) {
  const link = $('#open-windows-app');
  link.href = callback;
  $('#login-panel').hidden = true;
  $('#windows-handoff').hidden = false;
  $('#windows-handoff').focus();
  try { window.location.assign(callback); } catch { /* The browser may require a click on the link. */ }

  const code = new URL(callback).searchParams.get('code');
  const received = await waitForWindowsHandoff(() => api('/api/auth/login/windows-handoff', { code }));
  link.removeAttribute('href');
  link.hidden = true;
  setText('#windows-handoff-help', received ? 'passkey.login.handoffReceived' : 'passkey.login.handoffRetry');
  if (received) window.close();
}

if (page === 'register') {
  const nicknameInput = $('#nickname');
  nicknameInput.addEventListener('input', () => {
    nicknameInput.removeAttribute('aria-invalid');
    message('#nickname-error');
    message('#error-message');
  });
  $('#register-form').addEventListener('submit', (event) => {
    event.preventDefault();
    if (busy) return;
    const nickname = $('#nickname').value;
    if (!/^[A-Za-z]{3,15}$/.test(nickname)) {
      nicknameInput.setAttribute('aria-invalid', 'true');
      message('#nickname-error', 'errors.INVALID_NICKNAME');
      nicknameInput.focus();
      return;
    }
    run($('#register-button'), async () => {
      nicknameInput.readOnly = true;
      try {
      const options = await api('/api/auth/register/begin', { nickname });
      const credential = await navigator.credentials.create({ publicKey: creationOptions(options.publicKey) });
      if (!credential) throw new LocalizedError('passkey.errors.notCreated');
      const receipt = await api('/api/auth/register/finish', credentialJSON(credential));
      $('#registration-panel').hidden = true;
      $('#receipt-panel').hidden = false;
      $('#receipt-value').value = receipt.request_id;
      $('#copy-receipt').focus();
      } finally { nicknameInput.readOnly = false; }
    });
  });
  $('#copy-receipt').addEventListener('click', async () => {
    try { await navigator.clipboard.writeText($('#receipt-value').value); message('#copy-message', 'passkey.receipt.copied'); }
    catch { $('#receipt-value').select(); message('#copy-message', 'passkey.receipt.manualCopy'); }
  });
} else if (page === 'device') {
  const parameters = new URLSearchParams(window.location.search);
  const requestID = parameters.get('request') || '';
  if (parameters.getAll('request').length !== 1 || !/^[A-Za-z0-9_-]{43}$/.test(requestID)) {
    $('#device-button').disabled = true;
    message('#error-message', 'passkey.errors.invalidDeviceRequest');
  }
  $('#device-button').addEventListener('click', () => run($('#device-button'), async () => {
    const options = await api('/api/auth/login/begin', {device_request: requestID});
    const credential = await navigator.credentials.get({publicKey: requestOptions(options.publicKey)});
    if (!credential) throw new LocalizedError('passkey.errors.notSelected');
    const result = await api('/api/auth/login/finish', credentialJSON(credential));
    if (result.status !== 'approved') throw new LocalizedError('passkey.errors.notApproved');
    $('#device-panel').hidden = true;
    $('#device-approved').hidden = false;
    $('#device-approved').focus();
  }));
} else {
  $('#login-button').addEventListener('click', () => run($('#login-button'), async () => {
    const options = await api('/api/auth/login/begin', clientAuthorization ? {client: clientAuthorization} : {});
    const credential = await navigator.credentials.get({ publicKey: requestOptions(options.publicKey) });
    if (!credential) throw new LocalizedError('passkey.errors.notSelected');
    const result = await api('/api/auth/login/finish', credentialJSON(credential));
    if (clientAuthorization) {
      const callback = nativeLoginCallback(clientAuthorization, result.redirect_url);
      if (!callback) throw new LocalizedError('passkey.errors.callback');
      if (clientAuthorization.client_id === 'chirp-windows') await returnToWindows(callback);
      else window.location.assign(callback);
    } else signedIn(result);
  }));
  $('#logout-button').addEventListener('click', async () => {
    if (busy) return;
    busy = true; $('#logout-button').disabled = true; message('#logout-error');
    try { await api('/api/auth/logout', {}); $('#signed-in-panel').hidden = true; $('#login-panel').hidden = false; $('#signed-in-name').textContent = ''; }
    catch (error) { message('#logout-error', friendlyError(error)); }
    finally { busy = false; $('#logout-button').disabled = false; }
  });
  if (clientAuthorization) {
    setText('#login-title', 'passkey.login.clientTitle');
    setText('.under-button', 'passkey.login.clientHelp');
  } else api('/api/session').then((result) => { if (result.member) signedIn(result.member); }).catch((error) => message('#error-message', friendlyError(error)));
}
