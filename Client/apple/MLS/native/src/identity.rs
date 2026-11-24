//! Independent V5 credential verification. The expected owner comes from the
//! client's persistent, out-of-band verified room trust, never the snapshot.
use super::{Peer, Result, B64};
use base64::Engine;
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|t| t.as_secs())
        .unwrap_or(u64::MAX)
}
pub fn message(domain: &str, fields: &[&[u8]]) -> Vec<u8> {
    let mut result = Vec::new();
    for field in std::iter::once(domain.as_bytes()).chain(fields.iter().copied()) {
        result.extend_from_slice(&(field.len() as u32).to_be_bytes());
        result.extend_from_slice(field);
    }
    result
}
fn text_message(domain: &str, fields: &[String]) -> Vec<u8> {
    message(
        domain,
        &fields.iter().map(|s| s.as_bytes()).collect::<Vec<_>>(),
    )
}
pub fn hash(bytes: &[u8]) -> String {
    B64.encode(Sha256::digest(bytes))
}
fn decode(value: &str, count: usize) -> Result<Vec<u8>> {
    let bytes = B64.decode(value).map_err(|_| "invalid V5 encoding")?;
    if bytes.len() != count || B64.encode(&bytes) != value {
        return Err("invalid V5 encoding");
    }
    Ok(bytes)
}
pub fn verify(key: &str, signature: &str, bytes: &[u8]) -> Result<()> {
    let key: [u8; 32] = decode(key, 32)?.try_into().map_err(|_| "invalid V5 key")?;
    let signature =
        Signature::from_slice(&decode(signature, 64)?).map_err(|_| "invalid V5 signature")?;
    VerifyingKey::from_bytes(&key)
        .map_err(|_| "invalid V5 key")?
        .verify_strict(bytes, &signature)
        .map_err(|_| "invalid V5 signature")
}
fn time(start: u64, end: u64, maximum: u64, now: u64) -> Result<()> {
    if start == 0
        || end <= start
        || end - start > maximum
        || start > now.saturating_add(60)
        || end <= now
    {
        return Err("expired or invalid V5 authorization");
    }
    Ok(())
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Certificate {
    pub account_key: String,
    pub device_key: String,
    pub issuer_key: String,
    pub parent_hash: String,
    pub serial: String,
    pub can_enroll: bool,
    pub not_before: u64,
    pub not_after: u64,
    pub signature: String,
}
impl Certificate {
    pub fn message(&self) -> Vec<u8> {
        text_message(
            "Chirp device certificate v5",
            &[
                self.account_key.clone(),
                self.device_key.clone(),
                self.issuer_key.clone(),
                self.parent_hash.clone(),
                self.serial.clone(),
                if self.can_enroll { "1" } else { "0" }.into(),
                self.not_before.to_string(),
                self.not_after.to_string(),
            ],
        )
    }
    pub fn hash(&self) -> String {
        hash(&message(
            "Chirp device certificate digest v5",
            &[&self.message(), self.signature.as_bytes()],
        ))
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Device {
    pub account_key: String,
    pub certificates: Vec<Certificate>,
}
impl Device {
    pub fn leaf_key(&self) -> Result<&str> {
        self.certificates
            .last()
            .map(|c| c.device_key.as_str())
            .ok_or("V5 device certificate missing")
    }
    pub fn hash(&self) -> String {
        let mut fields = vec![
            self.account_key.clone(),
            self.certificates.len().to_string(),
        ];
        fields.extend(self.certificates.iter().map(Certificate::hash));
        hash(&text_message("Chirp device identity digest v5", &fields))
    }
    pub fn validate(&self, now: u64) -> Result<()> {
        decode(&self.account_key, 32)?;
        if self.certificates.is_empty() || self.certificates.len() > 8 {
            return Err("invalid V5 certificate path");
        }
        let mut issuer = self.account_key.clone();
        let mut parent = String::new();
        let mut deadline = u64::MAX;
        let mut seen = BTreeSet::from([issuer.clone()]);
        for (index, c) in self.certificates.iter().enumerate() {
            decode(&c.device_key, 32)?;
            decode(&c.serial, 16)?;
            if c.account_key != self.account_key
                || c.issuer_key != issuer
                || c.parent_hash != parent
                || !seen.insert(c.device_key.clone())
                || c.not_after > deadline
                || (index + 1 < self.certificates.len() && !c.can_enroll)
            {
                return Err("invalid V5 certificate path");
            }
            time(c.not_before, c.not_after, 5 * 365 * 24 * 3600, now)?;
            verify(&issuer, &c.signature, &c.message())?;
            issuer = c.device_key.clone();
            parent = c.hash();
            deadline = c.not_after;
        }
        Ok(())
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RoomPolicy {
    pub origin: String,
    pub room_id: String,
    pub trust_id: String,
    pub owner_key: String,
    pub version: u64,
    pub previous_hash: String,
    pub members: Vec<String>,
    pub revoked_devices: Vec<String>,
    pub not_before: u64,
    pub not_after: u64,
    pub signer: Device,
    pub signature: String,
}
impl RoomPolicy {
    pub fn message(&self) -> Vec<u8> {
        let mut f = vec![
            self.origin.clone(),
            self.room_id.clone(),
            self.trust_id.clone(),
            self.owner_key.clone(),
            self.version.to_string(),
            self.previous_hash.clone(),
            self.members.len().to_string(),
        ];
        f.extend(self.members.clone());
        f.push(self.revoked_devices.len().to_string());
        f.extend(self.revoked_devices.clone());
        f.extend([
            self.not_before.to_string(),
            self.not_after.to_string(),
            self.signer.hash(),
        ]);
        text_message("Chirp room policy v5", &f)
    }
    pub fn hash(&self) -> String {
        hash(&message(
            "Chirp room policy digest v5",
            &[&self.message(), self.signature.as_bytes()],
        ))
    }
    pub fn is_mutual(&self) -> bool {
        self.owner_key.is_empty()
    }
    pub fn allows(&self, device: &Device, now: u64) -> Result<()> {
        device.validate(now)?;
        if self.is_mutual() {
            return self.validate(now);
        }
        if !self.members.contains(&device.account_key) {
            return Err("untrusted account");
        }
        if self
            .revoked_devices
            .contains(&hash(&decode(device.leaf_key()?, 32)?))
        {
            return Err("revoked device");
        }
        Ok(())
    }
    pub fn validate(&self, now: u64) -> Result<()> {
        if self.is_mutual() {
            let expected = RoomPolicy {
                origin: self.origin.clone(),
                room_id: self.room_id.clone(),
                trust_id: hash(&message(
                    "Chirp mutual room v5",
                    &[self.origin.as_bytes(), self.room_id.as_bytes()],
                )),
                owner_key: String::new(),
                version: 1,
                previous_hash: String::new(),
                members: vec![],
                revoked_devices: vec![],
                not_before: 1,
                not_after: 253402300799,
                signer: Device {
                    account_key: String::new(),
                    certificates: vec![],
                },
                signature: String::new(),
            };
            if self.origin.is_empty() || self.room_id.is_empty() || self.hash() != expected.hash() {
                return Err("invalid mutual room context");
            }
            return Ok(());
        }
        let ordered = |v: &[String]| v.windows(2).all(|p| p[0] < p[1]);
        if self.origin.is_empty()
            || self.origin.len() > 2048
            || self.room_id.is_empty()
            || self.room_id.len() > 64
            || self.version == 0
            || self.version > i64::MAX as u64
            || self.members.is_empty()
            || self.members.len() > 1024
            || self.revoked_devices.len() > 1024
            || !ordered(&self.members)
            || !ordered(&self.revoked_devices)
            || self.owner_key != self.signer.account_key
            || !self.members.contains(&self.owner_key)
        {
            return Err("invalid V5 room policy");
        }
        decode(&self.trust_id, 32)?;
        if self.version == 1 {
            if !self.previous_hash.is_empty() {
                return Err("invalid V5 policy parent");
            }
        } else {
            decode(&self.previous_hash, 32)?;
        }
        for value in self.members.iter().chain(self.revoked_devices.iter()) {
            decode(value, 32)?;
        }
        time(self.not_before, self.not_after, 24 * 3600, now)?;
        self.allows(&self.signer, now)?;
        verify(self.signer.leaf_key()?, &self.signature, &self.message())
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EntryBinding {
    pub device: Device,
    pub origin: String,
    pub room_id: String,
    pub trust_id: String,
    pub policy_hash: String,
    pub identity: String,
    pub mls_key: String,
    pub nonce: String,
    pub not_before: u64,
    pub not_after: u64,
    pub signature: String,
}
impl EntryBinding {
    pub fn message(&self) -> Vec<u8> {
        text_message(
            "Chirp admission binding v5",
            &[
                self.device.hash(),
                self.origin.clone(),
                self.room_id.clone(),
                self.trust_id.clone(),
                self.policy_hash.clone(),
                self.identity.clone(),
                self.mls_key.clone(),
                self.nonce.clone(),
                self.not_before.to_string(),
                self.not_after.to_string(),
            ],
        )
    }
    pub fn hash(&self) -> String {
        hash(&message(
            "Chirp admission binding digest v5",
            &[&self.message(), self.signature.as_bytes()],
        ))
    }
    pub fn validate(&self, policy: &RoomPolicy, now: u64) -> Result<()> {
        decode(&self.mls_key, 32)?;
        decode(&self.nonce, 32)?;
        if self.origin != policy.origin
            || self.room_id != policy.room_id
            || self.trust_id != policy.trust_id
            || self.policy_hash != policy.hash()
            || self.identity.is_empty()
            || self.identity.len() > 192
            || self
                .identity
                .bytes()
                .any(|b| b == 0 || b == b'\n' || b == b'\r')
        {
            return Err("invalid V5 admission binding");
        }
        policy.allows(&self.device, now)?;
        time(self.not_before, self.not_after, 20 * 3600, now)?;
        verify(self.device.leaf_key()?, &self.signature, &self.message())
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RoundProof {
    pub group_id: String,
    pub key_epoch: u64,
    pub policy_hash: String,
    pub roster_hash: String,
    pub key_package_hash: String,
    pub signature: String,
}
impl RoundProof {
    pub fn message(&self) -> Vec<u8> {
        text_message(
            "Chirp round offer v5",
            &[
                self.group_id.clone(),
                self.key_epoch.to_string(),
                self.policy_hash.clone(),
                self.roster_hash.clone(),
                self.key_package_hash.clone(),
            ],
        )
    }
}

pub fn roster_hash(peers: &[Peer]) -> Result<String> {
    let mut hashes = peers
        .iter()
        .map(|p| {
            p.binding
                .as_ref()
                .map(EntryBinding::hash)
                .ok_or("V5 admission binding missing")
        })
        .collect::<Result<Vec<_>>>()?;
    hashes.sort();
    let mut fields = vec![hashes.len().to_string()];
    fields.extend(hashes);
    Ok(hash(&text_message("Chirp roster digest v5", &fields)))
}

pub fn validate_roster(
    policy: &RoomPolicy,
    peers: &[Peer],
    group_id: &str,
    key_epoch: u64,
    now: u64,
) -> Result<u64> {
    policy.validate(now)?;
    let hash = roster_hash(peers)?;
    let mut deadline = policy
        .signer
        .certificates
        .iter()
        .map(|c| c.not_after)
        .min()
        .unwrap_or(if policy.is_mutual() {
            policy.not_after
        } else {
            0
        })
        .min(policy.not_after);
    let mut devices = BTreeSet::new();
    for peer in peers {
        let binding = peer
            .binding
            .as_ref()
            .ok_or("V5 admission binding missing")?;
        binding.validate(policy, now)?;
        if binding.identity != peer.identity
            || binding.mls_key != peer.public_key
            || !devices.insert(binding.device.leaf_key()?.to_string())
        {
            return Err("V5 peer identity mismatch");
        }
        deadline = deadline.min(binding.not_after);
        for cert in &binding.device.certificates {
            deadline = deadline.min(cert.not_after);
        }
        if !peer.key_package.is_empty() {
            let offer = peer.offer.as_ref().ok_or("V5 round offer missing")?;
            if offer.group_id != group_id
                || offer.key_epoch != key_epoch
                || offer.policy_hash != policy.hash()
                || offer.roster_hash != hash
                || offer.key_package_hash
                    != self::hash(
                        &B64.decode(&peer.key_package)
                            .map_err(|_| "invalid V5 package")?,
                    )
            {
                return Err("V5 round offer mismatch");
            }
            verify(&peer.public_key, &offer.signature, &offer.message())?;
        }
    }
    Ok(deadline)
}
