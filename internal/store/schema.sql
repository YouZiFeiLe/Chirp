CREATE TABLE IF NOT EXISTS chirp_schema (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    version INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS registration_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    closed INTEGER NOT NULL CHECK (closed IN (0, 1))
) STRICT;
INSERT INTO registration_settings(id, closed) VALUES (1, 0) ON CONFLICT(id) DO NOTHING;

-- Fresh databases only

CREATE TABLE IF NOT EXISTS members (
    id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL,
    profile_revision INTEGER NOT NULL DEFAULT 0 CHECK (profile_revision >= 0),
    credential_hash BLOB NOT NULL UNIQUE CHECK (length(credential_hash) = 32),
    login_id TEXT NOT NULL DEFAULT '',
    room_join_sequence INTEGER NOT NULL DEFAULT 0 CHECK (room_join_sequence >= 0),
    credential_expires_at INTEGER NOT NULL DEFAULT 0,
    last_login_at TEXT NOT NULL DEFAULT '',
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    is_admin INTEGER NOT NULL DEFAULT 0 CHECK (is_admin IN (0, 1)),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS member_avatars (
    member_id TEXT PRIMARY KEY NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    image_data BLOB NOT NULL CHECK (length(image_data) > 0 AND length(image_data) < 5000000),
    revision TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS passkey_accounts (
    id TEXT PRIMARY KEY NOT NULL,
    nickname TEXT COLLATE NOCASE NOT NULL UNIQUE CHECK (length(nickname) BETWEEN 3 AND 15),
    request_id TEXT NOT NULL UNIQUE,
    member_id TEXT UNIQUE REFERENCES members(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    approved_at TEXT
) STRICT;

CREATE TABLE IF NOT EXISTS passkey_credentials (
    id BLOB PRIMARY KEY NOT NULL,
    account_id TEXT NOT NULL REFERENCES passkey_accounts(id) ON DELETE CASCADE,
    credential_json BLOB NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS passkey_ceremonies (
    token_hash BLOB PRIMARY KEY NOT NULL CHECK (length(token_hash) = 32),
    kind TEXT NOT NULL CHECK (kind IN ('register', 'login')),
    payload BLOB NOT NULL,
    expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS passkey_ceremonies_expiry ON passkey_ceremonies(expires_at);

CREATE TABLE IF NOT EXISTS passkey_sessions (
    token_hash BLOB PRIMARY KEY NOT NULL CHECK (length(token_hash) = 32),
    account_id TEXT NOT NULL REFERENCES passkey_accounts(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS passkey_sessions_expiry ON passkey_sessions(expires_at);

-- Begin native client authorizations
CREATE TABLE IF NOT EXISTS client_authorizations (
    code_hash BLOB PRIMARY KEY NOT NULL CHECK (length(code_hash) = 32),
    member_id TEXT NOT NULL UNIQUE REFERENCES members(id) ON DELETE CASCADE,
    client_id TEXT NOT NULL CHECK (client_id IN ('chirp-apple', 'chirp-windows', 'chirp-android')),
    code_challenge TEXT NOT NULL,
    expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS client_authorizations_expiry ON client_authorizations(expires_at);
-- End native client authorizations

CREATE TABLE IF NOT EXISTS room_settings (
    sort_order INTEGER PRIMARY KEY AUTOINCREMENT,
    room_id TEXT NOT NULL UNIQUE,
    deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
    display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
    description TEXT NOT NULL DEFAULT '一个房间，几个朋友，随时聊聊。' CHECK (length(description) BETWEEN 1 AND 280),
    password_salt BLOB,
    password_hash BLOB,
    password_revision INTEGER NOT NULL DEFAULT 0 CHECK (password_revision >= 0),
    CHECK (room_id <> 'friends' OR deleted = 0),
    CHECK ((password_salt IS NULL AND password_hash IS NULL) OR
        (password_salt IS NOT NULL AND password_hash IS NOT NULL AND
         length(password_salt) = 16 AND length(password_hash) = 32))
) STRICT;
INSERT INTO room_settings(room_id, display_name) VALUES ('friends', '公开大厅');

CREATE TABLE IF NOT EXISTS room_admissions (
    member_id TEXT PRIMARY KEY NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    login_id TEXT NOT NULL,
    entry_id TEXT NOT NULL UNIQUE,
    room_id TEXT NOT NULL REFERENCES room_settings(room_id),
    join_sequence INTEGER NOT NULL CHECK (join_sequence > 0),
    expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS room_admissions_room ON room_admissions(room_id, expires_at);

CREATE TABLE IF NOT EXISTS client_version_policies (
    platform TEXT PRIMARY KEY NOT NULL CHECK (platform IN ('ios', 'macos', 'windows', 'android')),
    latest_version TEXT NOT NULL,
    latest_build INTEGER NOT NULL CHECK (latest_build > 0),
    minimum_version TEXT NOT NULL,
    minimum_build INTEGER NOT NULL CHECK (minimum_build > 0),
    updated_at TEXT NOT NULL
) STRICT;
INSERT INTO client_version_policies(platform,latest_version,latest_build,minimum_version,minimum_build,updated_at) VALUES
    ('ios','2026.11.17',1,'2026.11.10',1,'2026-10-24T00:00:00Z'),
    ('macos','2026.11.17',1,'2026.11.10',1,'2026-10-24T00:00:00Z'),
    ('windows','2026.11.22',1,'2026.11.22',1,'2026-11-05T20:00:00Z'),
    ('android','2026.11.22',2,'2026.11.22',1,'2026-11-18T16:00:00Z');

CREATE TABLE IF NOT EXISTS room_attachments (
    id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 32),
    room_id TEXT NOT NULL REFERENCES room_settings(room_id),
    owner_identity TEXT NOT NULL,
    ciphertext_size INTEGER NOT NULL CHECK (ciphertext_size BETWEEN 16 AND 104865792),
    uploaded_chunks INTEGER NOT NULL DEFAULT 0 CHECK (uploaded_chunks >= 0),
    ciphertext_sha256 TEXT NOT NULL CHECK (length(ciphertext_sha256) = 64),
    state TEXT NOT NULL DEFAULT 'reserved' CHECK (state IN ('reserved','uploading','paused','completed','delivered','cancelled','expired')),
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    completed_at INTEGER NOT NULL DEFAULT 0,
    terminal_at INTEGER NOT NULL DEFAULT 0,
    expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS room_attachments_expiry ON room_attachments(expires_at);
CREATE TABLE IF NOT EXISTS attachment_recipients (
    attachment_id TEXT NOT NULL REFERENCES room_attachments(id) ON DELETE CASCADE,
    identity TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','received','skipped')),
    PRIMARY KEY (attachment_id, identity)
) STRICT;

CREATE TABLE IF NOT EXISTS attachment_chunks (
    attachment_id TEXT NOT NULL REFERENCES room_attachments(id) ON DELETE CASCADE,
    chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),
    sha256 TEXT NOT NULL CHECK (length(sha256) = 64),
    PRIMARY KEY (attachment_id, chunk_index)
) STRICT;

CREATE TABLE IF NOT EXISTS administrator_bootstrap (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    initialized_at TEXT NOT NULL
) STRICT;


CREATE TABLE member_identities (
    member_id TEXT PRIMARY KEY NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    account_key TEXT NOT NULL,
    device_identity BLOB NOT NULL,
    login_id TEXT NOT NULL
) STRICT;
CREATE TABLE room_identity_policies (
    room_id TEXT PRIMARY KEY NOT NULL REFERENCES room_settings(room_id) ON DELETE CASCADE,
    document BLOB NOT NULL
) STRICT;
CREATE TABLE room_identity_history (
    room_id TEXT NOT NULL REFERENCES room_settings(room_id) ON DELETE CASCADE,
    version INTEGER NOT NULL CHECK (version > 0),
    document BLOB NOT NULL,
    PRIMARY KEY (room_id, version)
) STRICT;

CREATE TABLE registered_devices (
    device_key TEXT PRIMARY KEY NOT NULL,
    member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    account_key TEXT NOT NULL,
    document BLOB NOT NULL,
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    last_login_at INTEGER NOT NULL DEFAULT 0
) STRICT;
CREATE INDEX registered_devices_member ON registered_devices(member_id);
CREATE TABLE identity_blacklist (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL CHECK(kind IN ('account', 'device')),
    subject TEXT NOT NULL,
    account_id TEXT NOT NULL,
    account_key TEXT NOT NULL,
    username TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE(kind, subject)
) STRICT;
CREATE TRIGGER identity_blacklist_no_delete BEFORE DELETE ON identity_blacklist BEGIN SELECT RAISE(ABORT, 'permanent blacklist'); END;
CREATE TRIGGER identity_blacklist_no_update BEFORE UPDATE ON identity_blacklist BEGIN SELECT RAISE(ABORT, 'permanent blacklist'); END;
CREATE TABLE identity_setups (
    token_hash BLOB PRIMARY KEY NOT NULL,
    member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    client_id TEXT NOT NULL,
    origin TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    candidate_root TEXT NOT NULL DEFAULT '',
    candidate_device TEXT NOT NULL DEFAULT '',
    challenge TEXT NOT NULL DEFAULT '',
    completed INTEGER NOT NULL DEFAULT 0
) STRICT;
CREATE TABLE account_social_events (
    member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    version INTEGER NOT NULL,
    document BLOB NOT NULL,
    PRIMARY KEY(member_id, version)
) STRICT;
CREATE TABLE identity_signals (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    sender TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    recipient TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    document BLOB NOT NULL,
    expires_at INTEGER NOT NULL
) STRICT;
CREATE TABLE retired_passkeys (
 credential_id BLOB PRIMARY KEY NOT NULL,
 account_id TEXT NOT NULL,
 nickname TEXT NOT NULL,
 credential_json BLOB NOT NULL,
 retired_at INTEGER NOT NULL,
 status TEXT NOT NULL CHECK (status IN ('rejected', 'blacklisted'))
) STRICT;

INSERT INTO chirp_schema(id, version) VALUES(1, 23);
