//! CHIRPKEY v1. Parameters and length are checked before any KDF allocation.
use super::{Result, B64};
use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::Engine;
use ed25519_dalek::SigningKey;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

const MAGIC: &[u8; 8] = b"CHIRPKEY";

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecoveryPayload {
    pub payload_version: u32,
    pub identity_protocol: String,
    pub root_algorithm: String,
    pub root_seed: String,
    pub root_public_key: String,
    pub service_origin: String,
    pub account_id: String,
    pub username: String,
    pub created_at: String,
    pub source_platform: String,
}
impl Drop for RecoveryPayload {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.root_seed.zeroize();
    }
}
impl RecoveryPayload {
    fn validate(&self) -> Result<()> {
        let seed = Zeroizing::new(
            B64.decode(&self.root_seed)
                .map_err(|_| "invalid recovery payload")?,
        );
        let seed: &[u8; 32] = seed
            .as_slice()
            .try_into()
            .map_err(|_| "invalid recovery seed")?;
        if self.payload_version != 1
            || self.identity_protocol != "chirp-mls-authenticated-v5"
            || self.root_algorithm != "Ed25519"
            || B64.encode(seed) != self.root_seed
            || B64.encode(SigningKey::from_bytes(seed).verifying_key().as_bytes())
                != self.root_public_key
            || self.account_id.is_empty()
            || self.account_id.len() > 128
            || self.username.len() > 320
            || self.created_at.is_empty()
            || !self.created_at.ends_with('Z')
            || !matches!(self.source_platform.as_str(), "iOS" | "macOS" | "Windows" | "Android")
            || self.service_origin.is_empty()
            || self.service_origin.len() > 2048
        {
            return Err("invalid recovery payload");
        }
        Ok(())
    }
}
fn key(password: &str, salt: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    if password.chars().count() < 16 || password.len() > 1024 {
        return Err("recovery password must contain at least 16 Unicode scalars and at most 1024 UTF-8 bytes");
    }
    let params = Params::new(65536, 3, 4, Some(32)).map_err(|_| "invalid KDF parameters")?;
    let mut key = Zeroizing::new([0u8; 32]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(password.as_bytes(), salt, key.as_mut())
        .map_err(|_| "recovery KDF failed")?;
    Ok(key)
}
pub fn encrypt(payload: &str, password: &str) -> Result<Vec<u8>> {
    // Deserializing the concrete struct rejects duplicate, unknown and missing fields.
    let value: RecoveryPayload =
        serde_json::from_str(payload).map_err(|_| "invalid recovery payload")?;
    value.validate()?;
    if payload.is_empty() || payload.len() > 65536 {
        return Err("invalid recovery payload length");
    }
    let mut header = Vec::with_capacity(54);
    header.extend_from_slice(MAGIC);
    header.extend_from_slice(&1u16.to_be_bytes());
    header.extend_from_slice(&1u16.to_be_bytes());
    header.extend_from_slice(&65536u32.to_be_bytes());
    header.extend_from_slice(&3u32.to_be_bytes());
    header.extend_from_slice(&4u16.to_be_bytes());
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut salt).map_err(|_| "secure random unavailable")?;
    getrandom::fill(&mut nonce).map_err(|_| "secure random unavailable")?;
    header.extend_from_slice(&salt);
    header.extend_from_slice(&nonce);
    header.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    let derived = key(password, &salt)?;
    let cipher =
        Aes256Gcm::new_from_slice(derived.as_ref()).map_err(|_| "recovery encryption failed")?;
    let ciphertext = cipher
        .encrypt(
            &Nonce::from(nonce),
            Payload {
                msg: payload.as_bytes(),
                aad: &header,
            },
        )
        .map_err(|_| "recovery encryption failed")?;
    header.extend(ciphertext);
    // Mandatory complete round trip before any caller may persist or export.
    let checked = decrypt(&header, password)?;
    if checked.as_bytes() != payload.as_bytes() {
        return Err("recovery self-test failed");
    }
    Ok(header)
}
pub fn decrypt(file: &[u8], password: &str) -> Result<Zeroizing<String>> {
    if file.len() < 71
        || file.len() > 54 + 65536 + 16
        || !file.starts_with(MAGIC)
        || file[8..22] != [0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 3, 0, 4]
    {
        return Err("unsupported or damaged recovery header");
    }
    let len = u32::from_be_bytes(
        file[50..54]
            .try_into()
            .map_err(|_| "invalid recovery length")?,
    ) as usize;
    if len == 0 || len > 65536 || file.len() != 54 + len + 16 {
        return Err("invalid recovery length");
    }
    let derived = key(password, &file[22..38])?;
    let cipher =
        Aes256Gcm::new_from_slice(derived.as_ref()).map_err(|_| "recovery decryption failed")?;
    let clear = Zeroizing::new(
        cipher
            .decrypt(
                &Nonce::from(
                    <[u8; 12]>::try_from(&file[38..50]).map_err(|_| "invalid recovery nonce")?,
                ),
                Payload {
                    msg: &file[54..],
                    aad: &file[..54],
                },
            )
            .map_err(|_| "wrong password or damaged recovery file")?,
    );
    let text =
        Zeroizing::new(String::from_utf8(clear.to_vec()).map_err(|_| "invalid recovery UTF-8")?);
    let value: RecoveryPayload =
        serde_json::from_str(&text).map_err(|_| "invalid recovery payload")?;
    value.validate()?;
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn payload() -> String {
        let seed = [7u8; 32];
        serde_json::json!({"payload_version":1,"identity_protocol":"chirp-mls-authenticated-v5","root_algorithm":"Ed25519","root_seed":B64.encode(seed),"root_public_key":B64.encode(SigningKey::from_bytes(&seed).verifying_key().as_bytes()),"service_origin":"https://fixture.test:443","account_id":"member_fixture","username":"Alice","created_at":"2026-11-17T00:00:00Z","source_platform":"iOS"}).to_string()
    }
    #[test]
    fn container_roundtrip_and_tamper() {
        let p = payload();
        let password = " long random password 😀 ";
        let f = encrypt(&p, password).unwrap();
        assert_eq!(&f[..8], b"CHIRPKEY");
        assert_eq!(*decrypt(&f, password).unwrap(), p);
        assert!(decrypt(&f, "different password!!!").is_err());
        for index in [0, 8, 12, 18, 22, 38, 50, 54, f.len() - 1] {
            let mut bad = f.clone();
            bad[index] ^= 1;
            assert!(decrypt(&bad, password).is_err());
        }
        let mut trailing = f.clone();
        trailing.push(0);
        assert!(decrypt(&trailing, password).is_err());
        assert!(decrypt(&f[..f.len() - 1], password).is_err());
    }
    #[test]
    fn payload_is_strict() {
        let p = payload();
        assert!(encrypt(
            &p.replacen("{", "{\"payload_version\":1,", 1),
            "long random password!!!"
        )
        .is_err());
        assert!(encrypt(&p.replace("\"iOS\"", "1"), "long random password!!!").is_err());
        assert!(encrypt(&p, "short").is_err());
    }
    #[test]
    fn exact_password_bytes() {
        let p = payload();
        let f = encrypt(&p, "  sixteen scalars plus  ").unwrap();
        assert!(decrypt(&f, "sixteen scalars plus").is_err());
    }
    #[test]
    fn independent_go_recovery_vector() {
        let vector: serde_json::Value = serde_json::from_str(include_str!(
            "../../Tests/ChirpMLSTests/Fixtures/recovery-v1.json"
        ))
        .unwrap();
        let file = B64.decode(vector["file"].as_str().unwrap()).unwrap();
        let password = vector["password"].as_str().unwrap();
        assert_eq!(
            decrypt(&file, password).unwrap().as_str(),
            vector["payload"].as_str().unwrap()
        );
    }
}
