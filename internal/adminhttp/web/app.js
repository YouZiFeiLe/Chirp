import { initI18n, t, getLocale, setText, textBinding, LocalizedError, apiError } from '/assets/i18n.js';
import { isValidClientVersionPolicy } from '/assets/client-version.js';

initI18n();

const $ = (selector) => document.querySelector(selector);
const icons = {
  users: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2m20 0v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/><circle cx="9" cy="7" r="4"/>',
  radio: '<circle cx="12" cy="12" r="2"/><path d="M16.24 7.76a6 6 0 0 1 0 8.48m-8.48 0a6 6 0 0 1 0-8.48m11.31-2.83a10 10 0 0 1 0 14.14m-14.14 0a10 10 0 0 1 0-14.14"/>',
  sliders: '<path d="M4 21v-7m0-4V3m8 18v-9m0-4V3m8 18v-5m0-4V3M1 14h6m2-6h6m2 8h6"/>',
  shield: '<path d="m12 3 8 4v6c0 5-8 9-8 9s-8-4-8-9V7l8-4Z"/><path d="m9 12 2 2 4-4"/>',
  refresh: '<path d="M20 7v5h-5M4 17v-5h5"/><path d="M6.09 7a7 7 0 0 1 11.55-2.64L20 7M4 17l2.36 2.64A7 7 0 0 0 17.91 17"/>',
  headphones: '<path d="M3 14v-3a9 9 0 0 1 18 0v3M5 13H3v7h4v-7H5Zm14 0h2v7h-4v-7h2Z"/>',
  activity: '<path d="M2 12h5l3-8 4 16 3-8h5"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6m0-10h.01"/>',
  'arrow-right': '<path d="M4 12h16m-6-6 6 6-6 6"/>',
  key: '<circle cx="8" cy="8" r="5"/><path d="m11.5 11.5 9 9m-3-3 3-3m-6 0 3-3"/>',
  lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3m-4 5v2"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  'phone-off': '<path d="m3 3 18 18M10.68 14.27a16 16 0 0 1-3-3l1.7-1.7L6 3H3a2 2 0 0 0-2 2c0 10 8 18 18 18a2 2 0 0 0 2-2v-3l-6.57-3.38-1.7 1.7M15 3a7 7 0 0 1 6 6"/>',
  external: '<path d="M14 3h7v7m0-7L11 13m-1-8H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5"/>',
  x: '<path d="m6 6 12 12M6 18 18 6"/>',
  edit: '<path d="m16 3 5 5-12 12-6 1 1-6L16 3Zm-2 2 5 5"/>',
  trash: '<path d="M3 6h18M9 6V3h6v3m-10 0 1 15h12l1-15M10 10v7m4-7v7"/>',
};
const icon = (name) => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.info}</svg>`;
document.querySelectorAll('[data-icon]').forEach((element) => { element.innerHTML = icon(element.dataset.icon); });

const escapeHTML = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
const h = (key, params) => escapeHTML(t(key, params));
// Match the native clients: the same member keeps the same avatar color everywhere.
const avatarTone = (identity) => Array.from(identity.split('.login_')[0]).reduce((sum, character) => sum + character.codePointAt(0), 0) % 4;
let overview = null;
let lastSyncedAt = null;
let lastRefreshError = null;
let editingMember = null;
let confirmAction = null;
let busy = false;
let refreshing = false;
let loadSequence = 0;
let selectedRoomID = null;
const roomNameDrafts = new Map();
const roomDescriptionDrafts = new Map();
let clientPolicies = [];
const clientPlatformNames = new Map([['ios', 'iOS'], ['macos', 'macOS'], ['windows', 'Windows'], ['android', 'Android']]);
let selectedPlatform = 'ios';
const versionDrafts = new Map();
const currentRoom = () => overview.rooms.find((room) => room.room_id === selectedRoomID) || overview.rooms[0];
let toastTimer;
let memberFilter = 'all';
let registrationFilter = 'pending';

async function api(path, method = 'GET', body) {
  try {
    const response = await fetch(`/admin/api${path}`, {
      method,
      headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: 'no-store',
      credentials: 'same-origin',
      signal: AbortSignal.timeout(12000),
    });
    if (response.status === 401) window.location.replace('/?admin=1');
    if (response.status === 204) return null;
    const contentType = response.headers.get('Content-Type') || '';
    const result = contentType.includes('application/json') ? await response.json() : null;
    if (!response.ok) {
      throw apiError(result?.error, path, response.status);
    }
    if (!result) throw new LocalizedError('errors.response');
    return result;
  } catch (error) {
    if (error.name === 'TimeoutError' || error.name === 'AbortError') throw new LocalizedError('errors.timeout');
    if (error instanceof TypeError) throw new LocalizedError('errors.network');
    throw error instanceof LocalizedError ? error : new LocalizedError('errors.operation');
  }
}

function message(selector, key = '', params = {}) {
  setText(selector, key, params);
  $(selector).hidden = !key;
}

function toast(key) {
  clearTimeout(toastTimer);
  setText('#toast-message', key);
  $('#toast').hidden = false;
  toastTimer = setTimeout(() => { $('#toast').hidden = true; }, 4000);
}

function connection(key, good) {
  setText('#connection-label', key);
  $('#connection-dot').className = `status-dot ${good ? 'good' : 'bad'}`;
}

function renderMembers() {
  if (!overview) return;
  const search = $('#member-search').value.trim().toLocaleLowerCase(getLocale());
  const members = overview.members.filter((member) =>
    (memberFilter === 'all' || member.enabled === (memberFilter === 'enabled')) &&
    `${member.display_name} ${member.id}`.toLocaleLowerCase(getLocale()).includes(search));
  setText('#member-results', 'admin.members.results', {count: members.length});
  const participantRooms = new Map(overview.rooms.flatMap((room) => (room.participants || []).map((participant) => [participant.id.split('.')[0], room.display_name])));
  const participants = new Set(participantRooms.keys());
  const statusKnown = overview.media_status === 'available';
  $('#members-body').innerHTML = members.length ? members.map((member) => {
    const name = escapeHTML(member.display_name);
    const id = escapeHTML(member.id);
    const online = participants.has(member.id);
    const accessKey = 'admin.identity.ban';
    return `<tr>
      <td data-label="${h('admin.columns.member')}"><div class="member-identity"><span class="member-avatar tone-${avatarTone(member.id)}" aria-hidden="true">${escapeHTML(Array.from(member.display_name)[0] || '?')}</span><div><span class="member-name">${name}</span><span class="member-id" title="${id}">${id}</span></div></div></td>
      <td data-label="${h('admin.columns.access')}"><span class="pill ${member.enabled ? 'enabled' : 'disabled'}"><span class="tiny-dot"></span>${h(member.enabled ? 'common.enabled' : 'common.disabled')}</span></td>
      <td data-label="${h('admin.columns.room')}"><span class="online-state ${online && statusKnown ? 'online' : 'offline'}"><span class="tiny-dot"></span>${online ? escapeHTML(participantRooms.get(member.id)) : h(statusKnown ? 'admin.members.notJoined' : 'admin.members.unknown')}</span></td>
      <td data-label="${h('admin.columns.created')}">${escapeHTML(formatDate(member.created_at))}</td>
      <td data-label="${h('admin.columns.login')}"><span>${h(member.login_active ? 'admin.members.signedIn' : 'admin.members.signedOut')}</span><span class="login-detail">${member.last_login_at ? h('admin.members.lastLogin', {time: formatDateTime(member.last_login_at)}) : h('admin.members.neverSignedIn')}</span>${member.login_active ? `<span class="login-detail">${h('admin.members.expires', {time: formatDateTime(member.credential_expires_at * 1000)})}</span>` : ''}</td>
      <td data-label="${h('admin.columns.actions')}"><div class="row-actions"><button type="button" class="text-button" data-action="edit" data-id="${id}" aria-label="${h('admin.members.editLabel', {name: member.display_name})}">${h('common.edit')}</button>${member.enabled ? `<button type="button" class="text-button" data-action="toggle" data-id="${id}">${h(accessKey)}</button>` : `<span>${h('admin.identity.permanent')}</span>`}<button type="button" class="text-button" data-action="devices" data-id="${id}">${h('admin.identity.devices')}</button>${member.login_active ? `<button type="button" class="text-button" data-action="revoke" data-id="${id}" aria-label="${h('admin.members.revokeLabel', {name: member.display_name})}">${h('common.logout')}</button>` : ''}<span class="action-divider"></span><button type="button" class="icon-button" data-action="delete" data-id="${id}" aria-label="${h('admin.members.deleteLabel', {name: member.display_name})}" title="${h('admin.members.delete')}">${icon('trash')}</button></div></td>
    </tr>`;
  }).join('') : `<tr><td colspan="6" class="empty-cell"><strong>${h(search ? 'admin.members.notFound' : 'admin.members.empty')}</strong><p>${h(search ? 'admin.members.searchHelp' : 'admin.members.emptyHelp')}</p></td></tr>`;
  $('#member-total').textContent = overview.members.length;
  $('#nav-count').textContent = overview.members.filter((member) => member.enabled).length;
  updateButtons();
}

function formatDate(value) {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? '—' : new Intl.DateTimeFormat(getLocale(), { year: 'numeric', month: '2-digit', day: '2-digit' }).format(date);
}

function formatDateTime(value) {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? '—' : date.toLocaleString(getLocale(), { hour12: false });
}

function formatDeviceTime(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
    ? formatDateTime(value * 1000) : t('admin.identity.noTimeRecord');
}

function renderParticipants() {
  const available = currentRoom().media_status === 'available';
  const participants = currentRoom().participants || [];
  $('#online-count').textContent = available ? participants.length : '—';
  const byID = new Map(overview.members.map((member) => [member.id, member]));
  $('#participants-list').innerHTML = !available
    ? `<div class="empty-description">${icon('activity')}${h('admin.participants.unavailable')}<br>${h('admin.participants.unavailableHelp')}</div>`
    : participants.length ? participants.map((participant) => {
      const member = byID.get(participant.id.split('.')[0]);
      const name = member?.display_name || participant.display_name || participant.id;
      return `<div class="participant"><span class="member-avatar tone-${avatarTone(participant.id)}" aria-hidden="true">${escapeHTML(Array.from(name)[0] || '?')}</span><div class="participant-info"><span class="member-name">${escapeHTML(name)}</span><span class="member-id" title="${escapeHTML(participant.id)}">${escapeHTML(participant.id)}</span></div><span class="pill enabled">${h('common.online')}</span><button type="button" class="text-button" data-remove="${escapeHTML(participant.id)}" aria-label="${h('admin.participants.removeLabel', {name})}">${h('admin.participants.remove')}</button></div>`;
    }).join('')
      : `<div class="empty-description"><span data-icon="headphones">${icon('headphones')}</span>${h('admin.participants.empty')}<br>${h('admin.participants.emptyHelp')}</div>`;
}

function renderRegistrationSettings() {
  const closed = overview?.registration_closed;
  $('#registration-closed').setAttribute('aria-checked', String(closed === true));
  if (typeof closed === 'boolean') {
    setText('#registration-status', closed ? 'admin.registrations.intakeClosed' : 'admin.registrations.intakeOpen');
  } else {
    setText('#registration-status', 'common.unavailable');
  }
}

function renderRegistrations() {
  if (!overview) return;
  const registrations = overview.registrations || [];
  const search = $('#registration-search').value.trim().toLowerCase();
  $('#registration-count').textContent = registrations.filter((item) => !item.member_id).length;
  $('#metric-pending').textContent = registrations.filter((item) => !item.member_id).length;
  const filtered = registrations.filter((item) =>
    (registrationFilter === 'all' || Boolean(item.member_id) === (registrationFilter === 'approved')) &&
    `${item.nickname} ${item.request_id}`.toLowerCase().includes(search));
  setText('#registration-results', 'admin.registrations.results', {count: filtered.length});
  const full = overview.max_members > 0 && overview.members.filter((member) => member.enabled).length >= overview.max_members;
  $('#registrations-list').innerHTML = filtered.length ? filtered.map((item) => `<article class="registration-item"><div class="registration-info"><div class="registration-heading"><strong>${escapeHTML(item.nickname)}</strong><span class="pill ${item.member_id ? 'enabled' : 'neutral'}">${h(item.member_id ? 'admin.registrations.approved' : 'admin.registrations.pending')}</span></div><code class="registration-id">${escapeHTML(item.request_id)}</code><p>${h('admin.registrations.createdAt', {date: formatDate(item.created_at)})}${item.member_id ? ` · ${h('admin.registrations.approvedAt', {date: formatDate(item.approved_at)})}` : ''}</p></div><div class="registration-actions">${item.member_id ? `<span class="field-help">${h('admin.registrations.manageMember')}</span>` : `<button class="button primary" type="button" data-registration-action="approve" data-id="${escapeHTML(item.request_id)}" ${full || busy ? 'disabled' : ''}>${h(full ? 'admin.registrations.full' : 'admin.registrations.approve')}</button><button class="button danger-outline" type="button" data-registration-action="delete" data-id="${escapeHTML(item.request_id)}" ${busy ? 'disabled' : ''}>${h('admin.registrations.delete')}</button>`}</div></article>`).join('') : `<p class="empty-description">${h(search ? 'admin.registrations.notFound' : 'admin.registrations.empty')}</p>`;
}

function renderSystem(apiAvailable = true) {
  const available = overview.media_status === 'available';
  $('#system-details').innerHTML = [
    ['admin.system.http', `<span class="pill ${apiAvailable ? 'enabled' : 'warning'}"><span class="tiny-dot"></span>${h(apiAvailable ? 'common.available' : 'admin.system.connectionFailed')}</span>`],
    ['admin.system.sqlite', `<code>${escapeHTML(overview.sqlite_version)}</code>`],
    ['admin.system.mediaAPI', `<span class="pill ${available ? 'enabled' : 'warning'}">${h(available ? 'common.available' : 'common.unavailable')}</span>`],
    ['admin.system.signaling', `<code>${escapeHTML(overview.livekit_url)}</code>`],
    ['admin.system.mediaTransport', escapeHTML(overview.media_transport.toUpperCase())],
    ['admin.system.audioE2EE', h(overview.e2ee_required ? 'admin.system.enforced' : 'admin.system.notEnabled')],
    ['admin.system.room', h('admin.system.roomCapacity', {name: currentRoom().display_name})],
    ['admin.rooms.password', h(currentRoom().password_required ? 'admin.system.passwordPolicy' : 'admin.rooms.noPassword')],
    ['admin.columns.login', h('admin.system.clientLogin')],
    ['admin.system.credentials', h('admin.system.credentialPolicy')],
    ['admin.system.adminAuth', h('admin.system.noAdminAuth')],
  ].map(([label, value]) => `<div><dt>${h(label)}</dt><dd>${value}</dd></div>`).join('');
}

function render({ syncStatus = true } = {}) {
  const enabled = overview.members.filter((member) => member.enabled).length;
  const available = overview.media_status === 'available';
  $('#metrics').setAttribute('aria-busy', 'false');
  $('#metric-members').textContent = enabled;
  setText('#metric-members-detail', 'admin.members.capacity');
  $('#metric-online').innerHTML = `${available ? overview.participants.length : '—'}<span>${h('admin.metrics.onlineUnit')}</span>`;
  setText('#metric-online-detail', available ? (overview.participants.length ? 'admin.metrics.talking' : 'admin.metrics.quiet') : 'admin.metrics.unknown');
  setText('#metric-service', available ? 'admin.metrics.available' : 'common.unavailable');
  $('#metric-service').classList.toggle('offline', !available);
  setText('#room-config-badge', 'admin.rooms.keyPolicyBadge');
  setText('#room-password-state', currentRoom().password_required ? 'admin.rooms.protected' : 'admin.rooms.noPassword');
  $('#room-password-state').className = `pill ${currentRoom().password_required ? 'enabled' : 'neutral'}`;
  $('#room-config-badge').className = 'pill neutral';
  $('#room-title').textContent = currentRoom().display_name;
  $('#room-shortcut-title').textContent = currentRoom().display_name;
  $('#room-select').innerHTML = overview.rooms.map((room) => `<option value="${escapeHTML(room.room_id)}">${escapeHTML(room.display_name)}${room.password_required ? h('admin.rooms.protectedSuffix') : ''}</option>`).join('');
  $('#room-select').value = selectedRoomID;
  $('#room-name').value = roomNameDrafts.get(selectedRoomID) ?? currentRoom().display_name;
  $('#room-description').value = roomDescriptionDrafts.get(selectedRoomID) ?? currentRoom().description;
  setText('#room-shortcut-description', 'admin.rooms.summary', {rooms: overview.rooms.length});
  renderSystem();
  renderClientVersions();
  renderMembers();
  renderParticipants();
  renderRegistrationSettings();
  renderRegistrations();
  if (syncStatus) {
    connection(available ? 'admin.connection.ready' : 'admin.connection.mediaUnavailable', available);
    message('#global-error', available ? '' : 'admin.errors.mediaUnavailable');
  }
  if (lastSyncedAt) setText('#last-updated', 'admin.lastSynced', {time: new Intl.DateTimeFormat(getLocale(), {hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false}).format(lastSyncedAt)});
  updateButtons();
}

function renderClientVersions() {
  const policy = clientPolicies.find((item) => item.platform === selectedPlatform);
  const value = versionDrafts.get(selectedPlatform) || policy;
  $('#version-platform').value = selectedPlatform;
  if (value) {
    $('#version-number').value = value.latest_version;
    $('#version-build').value = value.latest_build;
    $('#version-minimum-number').value = value.minimum_version;
    $('#version-minimum').value = value.minimum_build;
  }
  $('#version-policies').innerHTML = clientPolicies.map((item) => `<div><dt>${clientPlatformNames.get(item.platform)}</dt><dd>${h('admin.versions.summary', {version: item.latest_version, build: item.latest_build, minimumVersion: item.minimum_version, minimum: item.minimum_build})}</dd></div>`).join('');
}

function updateButtons() {
  const ready = Boolean(overview);
  $('#refresh-button').disabled = busy || refreshing;
  $('#refresh-button').setAttribute('aria-busy', String(refreshing));
  const registrationSwitch = $('#registration-closed');
  registrationSwitch.disabled = typeof overview?.registration_closed !== 'boolean';
  registrationSwitch.setAttribute('aria-disabled', String(busy || registrationSwitch.disabled));
  $('#room-name').disabled = busy;
  $('#room-description').disabled = busy || !ready;
  const versionsReady = ready && clientPolicies.length > 0;
  for (const id of ['version-platform', 'version-number', 'version-build', 'version-minimum-number', 'version-minimum']) $(`#${id}`).disabled = busy || !versionsReady;
  $('#version-submit').disabled = busy || !versionsReady || !versionDrafts.has(selectedPlatform);
  $('#room-password').disabled = busy || !ready;
  $('#room-password-submit').disabled = busy || !ready || !$('#room-password').value;
  $('#room-password-clear').disabled = busy || !ready || !currentRoom().password_required;
  if (!busy && ready) setText('#room-password-submit', currentRoom().password_required ? 'admin.rooms.changePassword' : 'admin.rooms.setPassword');
  $('#room-select').disabled = busy || !ready;
  $('#room-submit').disabled = busy || !ready || !roomNameDrafts.has(selectedRoomID);
  $('#room-description-submit').disabled = busy || !ready || !roomDescriptionDrafts.has(selectedRoomID);
  $('#end-room-button').disabled = busy || !ready;
  $('#delete-room-button').disabled = busy || !ready || currentRoom().is_default;
  $('#new-room-name').disabled = busy || !ready;
  $('#create-room-submit').disabled = busy || !ready || !$('#new-room-name').value.trim();
  document.querySelectorAll('#members-body button, #participants-list button').forEach((button) => { button.disabled = busy; });
  document.querySelectorAll('[data-registration-action]').forEach((button) => { button.disabled = busy || (button.dataset.registrationAction === 'approve' && overview.max_members > 0 && overview.members.filter((member) => member.enabled).length >= overview.max_members); });
}

async function refresh({ quiet = false } = {}) {
  const sequence = ++loadSequence;
  refreshing = true;
  $('#refresh-button').disabled = true;
  $('#refresh-button').setAttribute('aria-busy', 'true');
  if (!quiet) $('#metrics').setAttribute('aria-busy', 'true');
  try {
    const [next, versions] = await Promise.all([api('/overview'), api('/client-versions')]);
    if (sequence !== loadSequence) return;
    overview = next;
    clientPolicies = versions.platforms.filter((policy) => clientPlatformNames.has(policy.platform));
    if (!overview.rooms.some((room) => room.room_id === selectedRoomID)) {
      selectedRoomID = (overview.rooms.find((room) => room.is_default) || overview.rooms[0]).room_id;
      $('#room-password').value = '';
    }
    const roomIDs = new Set(overview.rooms.map((room) => room.room_id));
    for (const drafts of [roomNameDrafts, roomDescriptionDrafts]) {
      for (const id of drafts.keys()) if (!roomIDs.has(id)) drafts.delete(id);
    }
    lastSyncedAt = new Date();
    lastRefreshError = null;
    render();
  } catch (error) {
    if (sequence !== loadSequence) return;
    lastRefreshError = error;
    renderRefreshFailure(error);
  } finally {
    if (sequence === loadSequence) {
      refreshing = false;
      updateButtons();
      $('#metrics').setAttribute('aria-busy', 'false');
    }
  }
}

function renderRefreshFailure(error) {
  message('#global-error', overview ? 'admin.errors.stale' : error, {message: error});
  connection('admin.connection.failed', false);
  renderRegistrationSettings();
  if (overview) {
    overview.media_status = 'unavailable';
    overview.participants = null;
    overview.rooms.forEach((room) => { room.media_status = 'unavailable'; room.participants = null; });
    renderMembers();
    renderParticipants();
    renderRegistrations();
    renderSystem(false);
  }
  $('#metric-online').innerHTML = `—<span>${h('admin.metrics.onlineUnit')}</span>`;
  setText('#metric-online-detail', 'admin.metrics.syncFailed');
  setText('#metric-service', 'admin.metrics.disconnected');
  $('#metric-service').classList.add('offline');
  setText('#last-updated', 'admin.syncFailed');
  updateButtons();
}

const viewInfo = {
  members: ['admin.members.title', 'admin.members.description'],
  registrations: ['admin.registrations.title', 'admin.registrations.description'],
  room: ['admin.rooms.title', 'admin.rooms.description'],
  system: ['admin.system.title', 'admin.system.description'],
  versions: ['admin.versions.title', 'admin.versions.help'],
};
function navigate(event) {
  const selected = location.hash.slice(1);
  if (selected === 'main') { $('#main').focus(); return; }
  const view = Object.hasOwn(viewInfo, selected) ? selected : 'members';
  for (const name of Object.keys(viewInfo)) $(`#view-${name}`).hidden = name !== view;
  document.querySelectorAll('[data-view]').forEach((link) => {
    link.classList.toggle('active', link.dataset.view === view);
    if (link.dataset.view === view) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  });
  setText('#page-title', viewInfo[view][0]);
  setText('#page-description', viewInfo[view][1]);
  setText('#breadcrumb-current', viewInfo[view][0]);
  setText(document.querySelector('title'), 'admin.pageTitle', {page: {key: viewInfo[view][0]}});
  if (event?.type === 'hashchange') {
    window.scrollTo(0, 0);
    $('#main').focus({ preventScroll: true });
  }
}

function openMember(member) {
  editingMember = member;
  $('#member-form').reset();
  $('#member-name').value = member.display_name;
  $('#member-enabled').checked = member.enabled;
  $('#member-enabled').disabled = !member.enabled;
  $('#member-enabled-field').hidden = !member.enabled;
  message('#member-form-error');
  $('#member-dialog').showModal();
  $('#member-name').focus();
}

function confirm({ title, description, label, action, danger = true }) {
  confirmAction = action;
  setText('#confirm-title', title);
  setText('#confirm-description', description);
  setText('#confirm-button', label);
  $('#confirm-button').className = `button ${danger ? 'danger' : 'primary'}`;
  message('#confirm-error');
  $('#confirm-dialog').showModal();
}

async function mutate(action, { errorTarget, button } = {}) {
  if (busy || !overview) return;
  busy = true;
  ++loadSequence;
  refreshing = false;
  $('#metrics').setAttribute('aria-busy', 'false');
  updateButtons();
  if (errorTarget) { message(errorTarget); $(errorTarget).classList.remove('error-text'); }
  const original = button ? textBinding(button) : null;
  if (button) { button.disabled = true; setText(button, 'common.processing'); }
  // Keep mutations and confirmations attached to their initiating dialog.
  document.querySelectorAll('dialog [data-close-dialog]').forEach((close) => { close.disabled = true; });
  try {
    await action();
  } catch (error) {
    if (error.code === 'LOGIN_REVOKED_CLEANUP_PENDING' || error.code === 'ADMISSION_REVOKED_CLEANUP_PENDING' || error.code === 'ROOM_END_INCOMPLETE') await refresh({ quiet: true });
    if (errorTarget) { message(errorTarget, error); $(errorTarget).classList.add('error-text'); }
    else message('#global-error', error);
  } finally {
    busy = false;
    if (button) { button.disabled = false; setText(button, original); }
    document.querySelectorAll('dialog [data-close-dialog]').forEach((close) => { close.disabled = false; });
    updateButtons();
  }
}

$('#version-platform').addEventListener('change', () => {
  const platform = $('#version-platform').value;
  if (!clientPlatformNames.has(platform)) return;
  selectedPlatform = platform;
  message('#version-form-error'); renderClientVersions(); updateButtons();
});
for (const id of ['version-number', 'version-build', 'version-minimum-number', 'version-minimum']) $(`#${id}`).addEventListener('input', () => {
  versionDrafts.set(selectedPlatform, {latest_version: $('#version-number').value, latest_build: $('#version-build').value, minimum_version: $('#version-minimum-number').value, minimum_build: $('#version-minimum').value});
  updateButtons();
});
$('#version-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const platform = selectedPlatform;
  const value = {latest_version: $('#version-number').value.trim(), latest_build: Number($('#version-build').value), minimum_version: $('#version-minimum-number').value.trim(), minimum_build: Number($('#version-minimum').value)};
  if (!isValidClientVersionPolicy(value)) {
    message('#version-form-error', 'errors.INVALID_CLIENT_POLICY'); return;
  }
  mutate(async () => {
    const saved = await api(`/client-versions/${encodeURIComponent(platform)}`, 'PUT', value);
    clientPolicies = clientPolicies.map((item) => item.platform === platform ? saved : item);
    versionDrafts.delete(platform);
    renderClientVersions(); toast('admin.versions.saved');
    await refresh({quiet: true});
  }, {errorTarget: '#version-form-error', button: $('#version-submit')});
});

$('#member-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const member = editingMember;
  if (!member) return;
  const displayName = $('#member-name').value.trim();
  if (!displayName) { message('#member-form-error', 'admin.members.enterName'); return; }
  const enabled = $('#member-enabled').checked;
  mutate(async () => {
    await api(`/members/${encodeURIComponent(member.id)}`, 'PUT', { display_name: displayName, enabled });
    $('#member-dialog').close();
    toast('admin.members.saved');
    await refresh({ quiet: true });
  }, { errorTarget: '#member-form-error', button: $('#member-submit') });
});

$('#members-body').addEventListener('click', (event) => {
  const button = event.target.closest('[data-action]');
  if (!button || busy) return;
  const member = overview.members.find((item) => item.id === button.dataset.id);
  if (!member) return;
  if (button.dataset.action === 'devices') { openDevices(member).catch((error) => message('#global-error', error)); return; }
  if (button.dataset.action === 'edit') { openMember(member); return; }
  if (button.dataset.action === 'delete') {
    confirm({ title: {key: 'admin.confirm.deleteMember', params: {name: member.display_name}}, description: 'admin.confirm.deleteMemberHelp', label: 'admin.members.delete', action: async () => {
      await api(`/members/${encodeURIComponent(member.id)}`, 'DELETE');
      $('#confirm-dialog').close();
      toast('admin.members.deleted');
      await refresh({ quiet: true });
    } });
  } else if (button.dataset.action === 'revoke' && member.participant_identity) {
    confirm({ title: {key: 'admin.confirm.revokeLogin', params: {name: member.display_name}}, description: 'admin.confirm.revokeLoginHelp', label: 'admin.confirm.revoke', action: async () => {
      await api(`/members/${encodeURIComponent(member.id)}/revoke-login`, 'POST', { participant_identity: member.participant_identity });
      $('#confirm-dialog').close();
      toast('admin.members.revoked');
      await refresh({ quiet: true });
    } });
  } else if (button.dataset.action === 'toggle') {
    if (!member.enabled) return;
    {
      confirm({ title: {key: 'admin.confirm.disableMember', params: {name: member.display_name}}, description: 'admin.confirm.disableMemberHelp', label: 'admin.confirm.disable', action: async () => {
        await api(`/members/${encodeURIComponent(member.id)}`, 'PUT', { display_name: member.display_name, enabled: false });
        $('#confirm-dialog').close();
        toast('admin.members.disabled');
        await refresh({ quiet: true });
      } });
    }
  }
});


$('#participants-list').addEventListener('click', (event) => {
  const button = event.target.closest('[data-remove]');
  if (!button || busy) return;
  const roomID = selectedRoomID;
  const participant = currentRoom().participants?.find((item) => item.id === button.dataset.remove);
  if (!participant) return;
  const member = overview.members.find((item) => item.id === participant.id.split('.')[0]);
  confirm({ title: {key: 'admin.confirm.removeParticipant', params: {name: member?.display_name || participant.display_name || participant.id}}, description: 'admin.confirm.removeParticipantHelp', label: 'admin.confirm.remove', action: async () => {
    await api(`/rooms/${encodeURIComponent(roomID)}/participants/${encodeURIComponent(participant.id)}`, 'DELETE');
    $('#confirm-dialog').close();
    toast('admin.participants.removed');
    await refresh({ quiet: true });
  } });
});
$('#end-room-button').addEventListener('click', () => {
  const roomID = selectedRoomID;
  const roomName = currentRoom().display_name;
  confirm({ title: {key: 'admin.confirm.endRoom', params: {name: roomName}}, description: 'admin.confirm.endRoomHelp', label: 'admin.confirm.end', action: async () => {
    await api(`/rooms/${encodeURIComponent(roomID)}/end`, 'POST', {});
    $('#confirm-dialog').close();
    toast('admin.rooms.ended');
    await refresh({ quiet: true });
  } });
});
$('#new-room-name').addEventListener('input', updateButtons);
$('#create-room-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const name = $('#new-room-name').value.trim();
  if (!name) return;
  mutate(async () => {
    const room = await api('/rooms', 'POST', {display_name: name});
    selectedRoomID = room.room_id;
    $('#new-room-name').value = '';
    toast('admin.rooms.created');
    await refresh({quiet: true});
  }, {errorTarget: '#create-room-error', button: $('#create-room-submit')});
});
$('#delete-room-button').addEventListener('click', () => {
  if (busy || !overview || currentRoom().is_default) return;
  const roomID = selectedRoomID;
  confirm({title: {key: 'admin.confirm.deleteRoom', params: {name: currentRoom().display_name}}, description: 'admin.confirm.deleteRoomHelp', label: 'admin.rooms.delete', action: async () => {
    const result = await api(`/rooms/${encodeURIComponent(roomID)}`, 'DELETE');
    $('#confirm-dialog').close();
    toast(result?.cleanup_pending ? 'admin.rooms.deletedPending' : 'admin.rooms.deleted');
    await refresh({quiet: true});
  }});
});
$('#confirm-button').addEventListener('click', () => { if (confirmAction) mutate(confirmAction, { errorTarget: '#confirm-error', button: $('#confirm-button') }); });

$('#room-name').addEventListener('input', () => { roomNameDrafts.set(selectedRoomID, $('#room-name').value); updateButtons(); });
$('#room-select').addEventListener('change', () => {
  selectedRoomID = $('#room-select').value;
  $('#room-password').value = '';
  message('#room-password-error');
  message('#room-form-error');
  message('#room-description-error');
  render();
});
$('#room-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const name = $('#room-name').value.trim();
  if (!name) { message('#room-form-error', 'admin.rooms.enterName'); return; }
  mutate(async () => {
    const roomID = selectedRoomID;
    const room = await api(`/rooms/${encodeURIComponent(roomID)}`, 'PUT', { display_name: name });
    const index = overview.rooms.findIndex((item) => item.room_id === roomID);
    overview.rooms[index] = { ...overview.rooms[index], ...room };
    roomNameDrafts.delete(roomID);
    render();
    toast('admin.rooms.saved');
    await refresh({ quiet: true });
  }, { errorTarget: '#room-form-error', button: $('#room-submit') });
});

$('#room-description').addEventListener('input', (event) => {
  const value = event.target.value;
  if (value === currentRoom().description) roomDescriptionDrafts.delete(selectedRoomID);
  else roomDescriptionDrafts.set(selectedRoomID, value);
  updateButtons();
});
$('#room-description-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const roomID = selectedRoomID;
  const description = $('#room-description').value.trim();
  if (Array.from(description).length > 280) {
    message('#room-description-error', 'errors.INVALID_ROOM_DESCRIPTION');
    return;
  }
  mutate(async () => {
    const saved = await api(`/rooms/${encodeURIComponent(roomID)}/description`, 'PUT', { description });
    currentRoom().description = saved.description;
    roomDescriptionDrafts.delete(roomID);
    render();
    toast('admin.rooms.descriptionSaved');
    await refresh({ quiet: true });
  }, { errorTarget: '#room-description-error', button: $('#room-description-submit') });
});

$('#room-password').addEventListener('input', updateButtons);
$('#room-password-form').addEventListener('submit', (event) => {
  event.preventDefault();
  if (busy || !overview) return;
  const input = $('#room-password');
  const password = input.value;
  const length = Array.from(password).length;
  if (length < 8 || length > 128 || new TextEncoder().encode(password).length > 512 || /\p{Cc}/u.test(password)) {
    message('#room-password-error', 'errors.INVALID_ROOM_PASSWORD');
    return;
  }
  const roomID = selectedRoomID;
  mutate(async () => {
    try {
      const config = await api(`/rooms/${encodeURIComponent(roomID)}/password`, 'PUT', { password });
      const index = overview.rooms.findIndex((item) => item.room_id === roomID);
      overview.rooms[index] = { ...overview.rooms[index], ...config };
      toast('admin.rooms.passwordSaved');
      render();
      await refresh({ quiet: true });
    } finally { input.value = ''; }
  }, { errorTarget: '#room-password-error', button: $('#room-password-submit') });
});
$('#room-password-clear').addEventListener('click', () => {
  if (busy || !overview) return;
  const roomID = selectedRoomID;
  const roomName = currentRoom().display_name;
  confirm({ title: {key: 'admin.confirm.clearPassword', params: {name: roomName}}, description: 'admin.confirm.clearPasswordHelp', label: 'admin.rooms.clearPassword', action: async () => {
    const config = await api(`/rooms/${encodeURIComponent(roomID)}/password`, 'DELETE');
    const index = overview.rooms.findIndex((item) => item.room_id === roomID);
    overview.rooms[index] = { ...overview.rooms[index], ...config };
    $('#room-password').value = '';
    message('#room-password-error');
    $('#confirm-dialog').close();
    render();
    toast('admin.rooms.passwordCleared');
    await refresh({ quiet: true });
  } });
});

document.querySelectorAll('[data-close-dialog]').forEach((button) => button.addEventListener('click', () => { if (!busy) $(`#${button.dataset.closeDialog}`).close(); }));
document.querySelectorAll('dialog').forEach((dialog) => dialog.addEventListener('cancel', (event) => { if (busy) event.preventDefault(); }));
$('#confirm-dialog').addEventListener('close', () => { confirmAction = null; });
$('#refresh-button').addEventListener('click', () => { if (!busy) refresh(); });
$('#member-search').addEventListener('input', renderMembers);
$('#registration-search').addEventListener('input', renderRegistrations);
$('#registration-closed').addEventListener('click', () => {
  const closed = overview?.registration_closed;
  if (typeof closed !== 'boolean') return;
  mutate(async () => {
    setText('#registration-status', 'common.processing');
    try {
      const settings = await api('/registration-settings', 'PUT', {registration_closed: !closed});
      overview.registration_closed = settings.registration_closed;
    } finally {
      renderRegistrationSettings();
    }
  }, {errorTarget: '#registration-settings-error'});
});
document.querySelectorAll('[data-member-filter]').forEach((button) => button.addEventListener('click', () => {
  memberFilter = button.dataset.memberFilter;
  document.querySelectorAll('[data-member-filter]').forEach((item) => item.setAttribute('aria-pressed', String(item === button)));
  renderMembers();
}));
document.querySelectorAll('[data-registration-filter]').forEach((button) => button.addEventListener('click', () => {
  registrationFilter = button.dataset.registrationFilter;
  document.querySelectorAll('[data-registration-filter]').forEach((item) => item.setAttribute('aria-pressed', String(item === button)));
  renderRegistrations();
}));
$('#registrations-list').addEventListener('click', (event) => {
  const button = event.target.closest('[data-registration-action]');
  if (!button || busy) return;
  const item = (overview?.registrations || []).find((request) => request.request_id === button.dataset.id);
  if (!item || item.member_id) return;
  const approve = button.dataset.registrationAction === 'approve';
  confirm({ title: approve ? {key: 'admin.confirm.approveRegistration', params: {name: item.nickname}} : {key: 'admin.confirm.deleteRegistration', params: {name: item.nickname}}, description: approve ? {key: 'admin.confirm.approveRegistrationHelp', params: {id: item.request_id}} : 'admin.confirm.deleteRegistrationHelp', label: approve ? 'admin.registrations.approve' : 'admin.registrations.delete', danger: !approve, action: async () => {
    await api(`/registrations/${encodeURIComponent(item.request_id)}${approve ? '/approve' : ''}`, approve ? 'POST' : 'DELETE', approve ? {} : undefined);
    $('#confirm-dialog').close();
    toast(approve ? 'admin.registrations.approvedToast' : 'admin.registrations.deletedToast');
    await refresh({ quiet: true });
  } });
});
window.addEventListener('chirp:languagechange', () => {
  navigate();
  if (overview) render({ syncStatus: false });
  if (lastRefreshError) renderRefreshFailure(lastRefreshError);
});
window.addEventListener('hashchange', navigate);
document.addEventListener('visibilitychange', () => { if (!document.hidden && !busy && !$('dialog[open]')) refresh({ quiet: true }); });
setInterval(() => { if (!document.hidden && !busy && !$('dialog[open]')) refresh({ quiet: true }); }, 15000);
navigate();
refresh();

$('#admin-logout').addEventListener('click', async () => {
  const button = $('#admin-logout');
  button.disabled = true;
  try {
    const response = await fetch('/api/auth/logout', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: '{}', credentials: 'same-origin', signal: AbortSignal.timeout(12000)});
    if (response.status !== 204) throw new LocalizedError('errors.operation');
    window.location.replace('/?admin=1');
  } catch (error) { toast('errors.operation'); button.disabled = false; }
});

async function deviceFingerprint(key) {
  const bytes = Uint8Array.from(atob(key), (c) => c.charCodeAt(0));
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), (b) => b.toString(16).padStart(2, '0')).join('');
}
async function openDevices(member) {
  const devices = await api(`/members/${encodeURIComponent(member.id)}/devices`);
  const rows = await Promise.all(devices.map(async (d) => `<article class="registration-item"><div class="registration-info"><strong>${escapeHTML(d.name)}</strong><p>${escapeHTML(d.platform)}</p><code>${await deviceFingerprint(d.device_key)}</code><p>${h(d.revoked ? 'admin.identity.permanent' : 'admin.identity.active')}</p><p>${h('admin.identity.lastOnline', {time: formatDeviceTime(d.last_login_at)})}</p><p>${h('admin.identity.firstRegistered', {time: formatDeviceTime(d.created_at)})}</p></div>${d.revoked ? '' : `<button type="button" class="button danger-outline" data-revoke-device="${escapeHTML(d.device_key)}" data-member="${escapeHTML(member.id)}">${h('admin.identity.revoke')}</button>`}</article>`));
  setText('#identity-dialog-title', 'admin.identity.devices');
  $('#identity-dialog-content').innerHTML = `<p>${h('admin.identity.deviceHelp')}</p><p>${h('admin.identity.timeHelp')}</p>${rows.join('') || `<p>${h('admin.identity.noDevices')}</p>`}`;
  $('#identity-dialog').showModal();
}
$('#show-blacklist').addEventListener('click', async () => {
  try {
    const records = await api('/blacklist');
    setText('#identity-dialog-title', 'admin.identity.blacklist');
    $('#identity-dialog-content').innerHTML = `<p>${h('admin.identity.permanentHelp')}</p>` + records.map((r) => `<article class="registration-item"><div><strong>${escapeHTML(r.username)}</strong><p>${escapeHTML(r.kind)} · ${escapeHTML(r.account_id)}</p><code>${escapeHTML(r.subject)}</code><p>${escapeHTML(formatDateTime(r.created_at * 1000))}</p></div></article>`).join('');
    $('#identity-dialog').showModal();
  } catch (error) { message('#global-error', error); }
});
$('#identity-dialog-content').addEventListener('click', (event) => {
  const button = event.target.closest('[data-revoke-device]'); if (!button || busy) return;
  $('#identity-dialog').close();
  confirm({title: 'admin.identity.revoke', description: 'admin.identity.deviceHelp', label: 'admin.identity.revoke', action: async () => {
    await api(`/members/${encodeURIComponent(button.dataset.member)}/devices/${encodeURIComponent(button.dataset.revokeDevice)}`, 'DELETE');
    $('#confirm-dialog').close(); await refresh({quiet: true});
  }});
});
