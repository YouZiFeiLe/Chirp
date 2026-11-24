//! Small C boundary around OpenMLS. JSON carries public keys/packages, request
//! signatures, encrypted Welcome messages, confirmations, and errors. Group state
//! stays in this client process; sender keys use a dedicated byte-buffer API.
use ::tls_codec::{Deserialize as TlsDeserialize, Serialize as TlsSerialize};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::{signatures::Signer, OpenMlsProvider};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::{c_char, CStr, CString},
    panic::{catch_unwind, AssertUnwindSafe},
    sync::Mutex,
};
use zeroize::Zeroize;
mod identity;
mod recovery;
mod security;

// Apple media authorization includes device sleep, unlike uptime-only timers.
#[cfg(target_vendor = "apple")]
fn continuous_ns() -> u64 {
    #[repr(C)]
    struct Timebase { numer: u32, denom: u32 }
    unsafe extern "C" {
        fn mach_continuous_time() -> u64;
        fn mach_timebase_info(info: *mut Timebase) -> i32;
    }
    let mut info = Timebase { numer: 0, denom: 0 };
    unsafe {
        if mach_timebase_info(&mut info) != 0 || info.denom == 0 { return u64::MAX; }
        ((mach_continuous_time() as u128 * info.numer as u128) / info.denom as u128).min(u64::MAX as u128) as u64
    }
}
#[cfg(windows)]
fn continuous_ns() -> u64 {
    // Interrupt time advances over sleep and is independent of wall-clock changes.
    #[link(name = "kernel32")]
    unsafe extern "system" { fn GetTickCount64() -> u64; }
    unsafe { GetTickCount64() }.saturating_mul(1_000_000)
}
#[cfg(target_os = "android")]
fn continuous_ns() -> u64 {
    // Android builds support 64-bit ABIs. CLOCK_BOOTTIME includes deep sleep.
    #[repr(C)]
    struct Timespec { seconds: i64, nanos: i64 }
    unsafe extern "C" { fn clock_gettime(clock: i32, time: *mut Timespec) -> i32; }
    let mut t = Timespec { seconds: 0, nanos: 0 };
    if unsafe { clock_gettime(7, &mut t) } != 0 { return u64::MAX; }
    (t.seconds as u64).saturating_mul(1_000_000_000).saturating_add(t.nanos as u64)
}
#[cfg(not(any(target_vendor = "apple", target_os = "android", windows)))]
fn continuous_ns() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos().min(u64::MAX as u128) as u64).unwrap_or(u64::MAX)
}

const SUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
type Result<T> = std::result::Result<T, &'static str>;

#[derive(Deserialize, Clone)]
#[serde(deny_unknown_fields)]
struct Peer {
    identity: String,
    public_key: String,
    #[serde(default)]
    key_package: String,
    #[serde(default, rename = "name")]
    _name: String,
    #[serde(default)]
    binding: Option<identity::EntryBinding>,
    #[serde(default)]
    offer: Option<identity::RoundProof>,
    #[serde(default)]
    ready: Option<serde_json::Value>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    operation: String,
    #[serde(default)]
    security: Option<Value>,
    #[serde(default)]
    group_id: String,
    #[serde(default)]
    members: Vec<Peer>,
    #[serde(default)]
    welcome: String,
    #[serde(default)]
    message: String,
    #[serde(default)]
    policy: Option<identity::RoomPolicy>,
    #[serde(default)]
    trusted_owner: String,
    #[serde(default)]
    origin: String,
    #[serde(default)]
    room_id: String,
    #[serde(default)]
    key_epoch: u64,
    #[serde(default)]
    authorization_hash: String,
}

struct Client {
    security: security::Security,
    identity: String,
    signer: SignatureKeyPair,
    provider: OpenMlsRustCrypto,
    group: Option<MlsGroup>,
    prepared: bool,
    staged: Option<Round>,
    trust: Option<identity::RoomPolicy>,
    approval: Option<(String, String, String)>,
    authorized_until: u64,
    created_at_ns: Option<u64>,
}

// Candidate state shares the admission's signer, but never the active round's
// secret storage. Swapping it in for an operation cannot erase active keys.
struct Round {
    provider: OpenMlsRustCrypto,
    group: Option<MlsGroup>,
    prepared: bool,
    authorized_until: u64,
    created_at_ns: Option<u64>,
}

impl Round {
    fn new() -> Self {
        Self {
            provider: OpenMlsRustCrypto::default(),
            group: None,
            prepared: false,
            authorized_until: 0,
            created_at_ns: None,
        }
    }
}

impl Drop for Round {
    fn drop(&mut self) {
        self.group = None;
        if let Ok(mut values) = self.provider.storage().values.write() {
            for value in values.values_mut() {
                value.zeroize();
            }
            values.clear();
        }
    }
}

impl Client {
    fn new(identity: &str) -> Result<Self> {
        if identity.is_empty() || identity.len() > 192 || !identity.is_ascii() {
            return Err("invalid client identity");
        }
        Ok(Self {
            security: security::Security::default(),
            identity: identity.into(),
            signer: SignatureKeyPair::new(SUITE.signature_algorithm())
                .map_err(|_| "signer generation failed")?,
            provider: OpenMlsRustCrypto::default(),
            group: None,
            prepared: false,
            staged: None,
            trust: None,
            approval: None,
            authorized_until: 0,
            created_at_ns: None,
        })
    }

    fn clear_round(&mut self) {
        self.staged = None;
        self.group = None;
        // OpenMLS's in-memory storage includes serialized secret copies. Wipe
        // values before replacing it; no persistence provider is configured.
        if let Ok(mut values) = self.provider.storage().values.write() {
            for value in values.values_mut() {
                value.zeroize();
            }
            values.clear();
        }
        self.provider = OpenMlsRustCrypto::default();
        self.prepared = false;
        self.authorized_until = 0;
        self.created_at_ns = None;
    }

    fn swap_round(&mut self, other: &mut Round) {
        std::mem::swap(&mut self.provider, &mut other.provider);
        std::mem::swap(&mut self.group, &mut other.group);
        std::mem::swap(&mut self.prepared, &mut other.prepared);
        std::mem::swap(&mut self.authorized_until, &mut other.authorized_until);
        std::mem::swap(&mut self.created_at_ns, &mut other.created_at_ns);
    }

    fn with_staged<T>(&mut self, action: impl FnOnce(&mut Self) -> Result<T>) -> Result<T> {
        let mut staged = self.staged.take().ok_or("candidate round not prepared")?;
        self.swap_round(&mut staged);
        let result = action(self);
        self.swap_round(&mut staged);
        self.staged = Some(staged);
        result
    }

    fn credential(&self) -> CredentialWithKey {
        CredentialWithKey {
            credential: BasicCredential::new(self.identity.as_bytes().to_vec()).into(),
            signature_key: self.signer.to_public_vec().into(),
        }
    }

    fn roster(&self, peers: &[Peer]) -> Result<BTreeMap<String, Vec<u8>>> {
        if peers.is_empty() {
            return Err("invalid group size");
        }
        let mut roster = BTreeMap::new();
        let mut keys = BTreeSet::new();
        for peer in peers {
            let public = B64
                .decode(&peer.public_key)
                .map_err(|_| "invalid identity public key")?;
            if peer.identity.is_empty()
                || peer.identity.len() > 192
                || public.len() != 32
                || roster
                    .insert(peer.identity.clone(), public.clone())
                    .is_some()
                || !keys.insert(public)
            {
                return Err("duplicate or invalid member identity");
            }
        }
        if roster.get(&self.identity) != Some(&self.signer.to_public_vec()) {
            return Err("own identity binding mismatch");
        }
        Ok(roster)
    }

    fn check_group(&self, group: &MlsGroup, id: &str, peers: &[Peer]) -> Result<()> {
        if id.is_empty()
            || id.len() > 192
            || group.group_id().as_slice() != id.as_bytes()
            || group.ciphersuite() != SUITE
        {
            return Err("group context mismatch");
        }
        let expected = self.roster(peers)?;
        let mut actual = BTreeMap::new();
        for member in group.members() {
            let credential = BasicCredential::try_from(member.credential)
                .map_err(|_| "unsupported member credential")?;
            let identity = std::str::from_utf8(credential.identity())
                .map_err(|_| "invalid member identity")?
                .to_string();
            if actual.insert(identity, member.signature_key).is_some() {
                return Err("duplicate group member");
            }
        }
        if actual != expected {
            return Err("authenticated group membership differs from admission roster");
        }
        Ok(())
    }

    fn confirmation(&self) -> Result<Value> {
        let group = self.group.as_ref().ok_or("group not ready")?;
        Ok(json!({"confirmation": B64.encode(group.epoch_authenticator().as_slice())}))
    }

    fn call(&mut self, mut request: Request) -> Result<Value> {
        if let Some(operation) = request.operation.strip_prefix("staged_") {
            if !matches!(operation, "key_package" | "create" | "join" | "lifetime") {
                return Err("invalid candidate operation");
            }
            let operation = operation.to_string();
            if operation == "key_package" {
                if self.group.is_none() || self.staged.is_some() {
                    return Err("candidate already prepared or active round missing");
                }
                self.staged = Some(Round::new());
            }
            request.operation = operation;
            return self.with_staged(|client| client.call(request));
        }
        match request.operation.as_str() {
            "security" => self
                .security
                .call(request.security.ok_or("security parameters missing")?),
            "approve" => {
                self.roster(&request.members)?;
                let hash = identity::roster_hash(&request.members)?;
                if request.group_id.is_empty() || request.authorization_hash.len() != 44
                    || B64.decode(&request.authorization_hash).map_or(true, |b| b.len() != 32) {
                    return Err("invalid V5 local roster approval");
                }
                self.approval = Some((request.group_id, hash, request.authorization_hash));
                Ok(json!({}))
            }
            "authorize" => {
                let policy = request.policy.ok_or("V5 room policy missing")?;
                policy.validate(identity::now())?;
                if policy.owner_key != request.trusted_owner
                    || policy.origin != request.origin
                    || policy.room_id != request.room_id
                {
                    return Err("V5 room trust mismatch");
                }
                self.trust = Some(policy);
                Ok(json!({}))
            }
            "activate_staged" => {
                let staged = self.staged.as_ref().ok_or("candidate round missing")?;
                if staged
                    .group
                    .as_ref()
                    .is_none_or(|group| group.group_id().as_slice() != request.group_id.as_bytes())
                {
                    return Err("candidate group context mismatch");
                }
                let mut staged = self.staged.take().ok_or("candidate round missing")?;
                self.swap_round(&mut staged);
                // Drop wipes the old round; it can never be reactivated.
                drop(staged);
                Ok(json!({}))
            }
            "discard_staged" => {
                self.staged = None;
                Ok(json!({}))
            }
            "identity" => Ok(json!({"public_key": B64.encode(self.signer.to_public_vec())})),
            "sign" => {
                let message = B64
                    .decode(request.message)
                    .map_err(|_| "invalid proof message")?;
                let allowed = message.starts_with(b"Chirp group request v5\n")
                    || message.starts_with(&identity::message("Chirp round offer v5", &[]))
                    || message.starts_with(&identity::message("Chirp epoch ready v5", &[]));
                if message.len() > 4096 || !allowed {
                    return Err("invalid proof domain");
                }
                let signature = self.signer.sign(&message).map_err(|_| "signature failed")?;
                Ok(json!({"signature": B64.encode(signature)}))
            }
            "lifetime" => {
                let start = self.created_at_ns.ok_or("key not created")?;
                let remaining = 120_000_000_000u64.saturating_sub(continuous_ns().saturating_sub(start)) / 1_000_000;
                if remaining == 0 { return Err("media key expired"); }
                Ok(json!({"milliseconds": remaining.to_string()}))
            }
            "clear" => {
                self.clear_round();
                Ok(json!({}))
            }
            "key_package" => {
                self.clear_round();
                let package = KeyPackage::builder()
                    .key_package_lifetime(Lifetime::new(120))
                    .build(SUITE, &self.provider, &self.signer, self.credential())
                    .map_err(|_| "key package generation failed")?;
                let public = package
                    .key_package()
                    .tls_serialize_detached()
                    .map_err(|_| "key package encoding failed")?;
                self.prepared = true;
                Ok(json!({"key_package": B64.encode(public)}))
            }
            "create" => {
                self.require_approval(&request)?;
                if self.created_at_ns.is_none() { self.created_at_ns = Some(continuous_ns()); }
                let policy = self
                    .trust
                    .as_ref()
                    .ok_or("V5 verified room trust required")?;
                self.authorized_until = identity::validate_roster(
                    policy,
                    &request.members,
                    &request.group_id,
                    request.key_epoch,
                    identity::now(),
                )?;
                if !self.prepared || self.group.is_some() {
                    return Err("fresh key package required");
                }
                self.roster(&request.members)?;
                if request.group_id.is_empty() || request.group_id.len() > 192 {
                    return Err("invalid group id");
                }
                let config = MlsGroupCreateConfig::builder()
                    .ciphersuite(SUITE)
                    .use_ratchet_tree_extension(true)
                    .max_past_epochs(0)
                    .build();
                let mut group = MlsGroup::new_with_group_id(
                    &self.provider,
                    &self.signer,
                    &config,
                    GroupId::from_slice(request.group_id.as_bytes()),
                    self.credential(),
                )
                .map_err(|_| "group creation failed")?;
                let mut packages = Vec::new();
                for peer in &request.members {
                    if peer.identity == self.identity {
                        continue;
                    }
                    let bytes = B64
                        .decode(&peer.key_package)
                        .map_err(|_| "invalid peer package")?;
                    if bytes.len() > 16384 {
                        return Err("peer package too large");
                    }
                    let package = KeyPackageIn::tls_deserialize_exact(bytes)
                        .map_err(|_| "peer package decoding failed")?
                        .validate(self.provider.crypto(), ProtocolVersion::Mls10)
                        .map_err(|_| "peer package validation failed")?;
                    let credential =
                        BasicCredential::try_from(package.leaf_node().credential().clone())
                            .map_err(|_| "unsupported peer credential")?;
                    if credential.identity() != peer.identity.as_bytes()
                        || package.leaf_node().signature_key().as_slice()
                            != B64
                                .decode(&peer.public_key)
                                .map_err(|_| "invalid public key")?
                    {
                        return Err("peer key package identity mismatch");
                    }
                    packages.push(package);
                }
                let welcome = if packages.is_empty() {
                    String::new()
                } else {
                    let (_, welcome, _) = group
                        .add_members(&self.provider, &self.signer, &packages)
                        .map_err(|_| "MLS admission failed")?;
                    group
                        .merge_pending_commit(&self.provider)
                        .map_err(|_| "MLS commit failed")?;
                    B64.encode(
                        welcome
                            .tls_serialize_detached()
                            .map_err(|_| "welcome encoding failed")?,
                    )
                };
                self.check_group(&group, &request.group_id, &request.members)?;
                self.group = Some(group);
                let mut result = self.confirmation()?;
                result["welcome"] = Value::String(welcome);
                Ok(result)
            }
            "join" => {
                self.require_approval(&request)?;
                if self.created_at_ns.is_none() { self.created_at_ns = Some(continuous_ns()); }
                let policy = self
                    .trust
                    .as_ref()
                    .ok_or("V5 verified room trust required")?;
                self.authorized_until = identity::validate_roster(
                    policy,
                    &request.members,
                    &request.group_id,
                    request.key_epoch,
                    identity::now(),
                )?;
                if !self.prepared || self.group.is_some() {
                    return Err("fresh key package required");
                }
                let bytes = B64.decode(request.welcome).map_err(|_| "invalid welcome")?;
                if bytes.len() > 131072 {
                    return Err("welcome too large");
                }
                let welcome = match MlsMessageIn::tls_deserialize_exact(bytes)
                    .map_err(|_| "welcome decoding failed")?
                    .extract()
                {
                    MlsMessageBodyIn::Welcome(welcome) => welcome,
                    _ => return Err("expected MLS Welcome"),
                };
                let config = MlsGroupJoinConfig::builder().max_past_epochs(0).build();
                let group = StagedWelcome::new_from_welcome(&self.provider, &config, welcome, None)
                    .map_err(|_| "welcome authentication failed")?
                    .into_group(&self.provider)
                    .map_err(|_| "welcome activation failed")?;
                self.check_group(&group, &request.group_id, &request.members)?;
                self.group = Some(group);
                self.confirmation()
            }
            _ => Err("unsupported native operation"),
        }
    }

    fn require_approval(&self, request: &Request) -> Result<()> {
        let (group, roster, _) = self.approval.as_ref().ok_or("V5 local roster approval required")?;
        if group != &request.group_id || roster != &identity::roster_hash(&request.members)? {
            return Err("V5 local roster approval changed");
        }
        Ok(())
    }

    fn media_key(&self, identity: &str) -> Result<Vec<u8>> {
        if self.authorized_until <= identity::now() || self.created_at_ns.is_none_or(|start| continuous_ns().saturating_sub(start) >= 120_000_000_000) {
            return Err("V5 authorization expired");
        }
        let group = self.group.as_ref().ok_or("group not ready")?;
        let present = group.members().any(|m| {
            BasicCredential::try_from(m.credential)
                .is_ok_and(|c| c.identity() == identity.as_bytes())
        });
        if !present {
            return Err("sender is not a group member");
        }
        group
            .export_secret(
                self.provider.crypto(),
                "Chirp LiveKit sender key v5",
                identity.as_bytes(),
                32,
            )
            .map_err(|_| "media key derivation failed")
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        self.clear_round();
    }
}

pub struct ChirpMLSContext(Mutex<Client>);

/// # Safety
/// `identity` must be null or a valid NUL-terminated UTF-8 string for this call.
#[no_mangle]
pub unsafe extern "C" fn chirp_mls_new(identity: *const c_char) -> *mut ChirpMLSContext {
    if identity.is_null() {
        return std::ptr::null_mut();
    }
    catch_unwind(|| {
        let identity = CStr::from_ptr(identity).to_str().ok()?;
        Client::new(identity)
            .ok()
            .map(|c| Box::into_raw(Box::new(ChirpMLSContext(Mutex::new(c)))))
    })
    .ok()
    .flatten()
    .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `context` must be null or a live handle returned by `chirp_mls_new`, freed
/// exactly once with no concurrent calls or remaining references.
#[no_mangle]
pub unsafe extern "C" fn chirp_mls_free(context: *mut ChirpMLSContext) {
    if !context.is_null() {
        drop(Box::from_raw(context));
    }
}

/// # Safety
/// `context` must be a live handle for the entire call; `request` must be a
/// valid NUL-terminated UTF-8 string. Free the returned string with this API.
#[no_mangle]
pub unsafe extern "C" fn chirp_mls_call(
    context: *mut ChirpMLSContext,
    request: *const c_char,
) -> *mut c_char {
    if context.is_null() || request.is_null() {
        return std::ptr::null_mut();
    }
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Value> {
        let bytes = CStr::from_ptr(request).to_bytes();
        if bytes.len() > 256 * 1024 {
            return Err("native request too large");
        }
        let request = serde_json::from_slice(bytes).map_err(|_| "invalid native request")?;
        (*context)
            .0
            .lock()
            .map_err(|_| "native context unavailable")?
            .call(request)
    }))
    .unwrap_or(Err("native operation failed"));
    let mut response = match result {
        Ok(value) => value,
        Err(error) => json!({"error": error}),
    };
    let encoded = response.to_string();
    security::clear_json(&mut response);
    CString::new(encoded)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `value` must be null or a string returned by `chirp_mls_call`, freed once.
#[no_mangle]
pub unsafe extern "C" fn chirp_mls_string_free(value: *mut c_char) {
    if !value.is_null() {
        let mut bytes = CString::from_raw(value).into_bytes_with_nul();
        bytes.zeroize();
    }
}

/// # Safety
/// `context` must be live, `identity` a valid NUL-terminated UTF-8 string, and
/// `output` a writable, non-overlapping buffer of at least 32 bytes.
#[no_mangle]
pub unsafe extern "C" fn chirp_mls_media_key(
    context: *mut ChirpMLSContext,
    identity: *const c_char,
    output: *mut u8,
) -> i32 {
    copy_media_key(context, identity, output, false)
}

/// # Safety
/// Same buffer and lifetime requirements as `chirp_mls_media_key`.
#[no_mangle]
pub unsafe extern "C" fn chirp_mls_staged_media_key(
    context: *mut ChirpMLSContext,
    identity: *const c_char,
    output: *mut u8,
) -> i32 {
    copy_media_key(context, identity, output, true)
}

unsafe fn copy_media_key(
    context: *mut ChirpMLSContext,
    identity: *const c_char,
    output: *mut u8,
    staged: bool,
) -> i32 {
    if context.is_null() || identity.is_null() || output.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| -> Result<()> {
        let identity = CStr::from_ptr(identity)
            .to_str()
            .map_err(|_| "invalid sender")?;
        let mut client = (*context)
            .0
            .lock()
            .map_err(|_| "native context unavailable")?;
        let mut key = if staged {
            client.with_staged(|candidate| candidate.media_key(identity))?
        } else {
            client.media_key(identity)?
        };
        std::ptr::copy_nonoverlapping(key.as_ptr(), output, 32);
        key.zeroize();
        Ok(())
    }))
    .ok()
    .and_then(|r| r.ok())
    .map(|_| 0)
    .unwrap_or(-1)
}

#[cfg(test)]
mod tests;
