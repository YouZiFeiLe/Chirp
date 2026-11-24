use super::*;
use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};

fn request(client: &mut Client, value: Value) -> Result<Value> {
    client.call(serde_json::from_value(value).unwrap())
}

#[test]
fn canonical_vectors_match_go_and_cryptokit() {
    let v: Value = serde_json::from_str(include_str!(
        "../../../../../internal/identity/testdata/v5.json"
    ))
    .unwrap();
    let device: identity::Device = serde_json::from_value(v["device"].clone()).unwrap();
    let policy: identity::RoomPolicy = serde_json::from_value(v["policy"].clone()).unwrap();
    let binding: identity::EntryBinding = serde_json::from_value(v["binding"].clone()).unwrap();
    let offer: identity::RoundProof = serde_json::from_value(v["offer"].clone()).unwrap();
    let now = v["now"].as_u64().unwrap();
    device.validate(now).unwrap();
    policy.validate(now).unwrap();
    binding.validate(&policy, now).unwrap();
    for (name, message) in [
        ("certificate", device.certificates[0].message()),
        ("policy", policy.message()),
        ("binding", binding.message()),
        ("offer", offer.message()),
    ] {
        assert_eq!(B64.encode(message), v["messages"][name].as_str().unwrap());
    }
    for (name, hash) in [
        ("certificate", device.certificates[0].hash()),
        ("device", device.hash()),
        ("policy", policy.hash()),
        ("binding", binding.hash()),
    ] {
        assert_eq!(hash, v["hashes"][name].as_str().unwrap());
    }
    identity::verify(&binding.mls_key, &offer.signature, &offer.message()).unwrap();
}

// Real V5 certificates and signatures are required by the production native
// boundary even in tests. These deterministic keys are public test fixtures.
fn device(identity: &str) -> (ed25519_dalek::SigningKey, identity::Device) {
    use ed25519_dalek::Signer;
    use sha2::{Digest, Sha256};
    let seed = |label: &str| -> [u8; 32] { Sha256::digest(label.as_bytes()).into() };
    let root = ed25519_dalek::SigningKey::from_bytes(&seed(&format!("test root {identity}")));
    let key = ed25519_dalek::SigningKey::from_bytes(&seed(&format!("test device {identity}")));
    let now = identity::now();
    let account = B64.encode(root.verifying_key().to_bytes());
    let mut certificate = identity::Certificate {
        account_key: account.clone(),
        device_key: B64.encode(key.verifying_key().to_bytes()),
        issuer_key: account.clone(),
        parent_hash: String::new(),
        serial: B64.encode([0u8; 16]),
        can_enroll: true,
        not_before: now - 1,
        not_after: now + 3600,
        signature: String::new(),
    };
    certificate.signature = B64.encode(root.sign(&certificate.message()).to_bytes());
    (
        key,
        identity::Device {
            account_key: account,
            certificates: vec![certificate],
        },
    )
}
fn policy(clients: &[&mut Client]) -> identity::RoomPolicy {
    use ed25519_dalek::Signer;
    let (key, signer) = device(&clients[0].identity);
    let mut members = clients
        .iter()
        .map(|c| device(&c.identity).1.account_key)
        .collect::<Vec<_>>();
    members.sort();
    let mut policy = identity::RoomPolicy {
        origin: "https://fixture.test".into(),
        room_id: "friends".into(),
        trust_id: identity::hash(b"test room"),
        owner_key: signer.account_key.clone(),
        version: 1,
        previous_hash: String::new(),
        members,
        revoked_devices: vec![],
        not_before: identity::now() - 1,
        not_after: identity::now() + 1800,
        signer,
        signature: String::new(),
    };
    policy.signature = B64.encode(key.sign(&policy.message()).to_bytes());
    policy
}
fn prepare(clients: &mut [&mut Client], group_id: &str, staged: bool) -> Vec<Peer> {
    use ed25519_dalek::Signer;
    let policy = if staged {
        clients[0].trust.clone().unwrap()
    } else {
        policy(clients)
    };
    let mut peers = Vec::new();
    for client in clients.iter_mut() {
        if !staged {
            request(client, json!({"operation":"authorize", "trusted_owner":policy.owner_key, "origin":policy.origin, "room_id":policy.room_id, "policy":policy})).unwrap();
        }
        let package = request(
            client,
            json!({"operation":if staged { "staged_key_package" } else { "key_package" }}),
        )
        .unwrap();
        let (key, device) = device(&client.identity);
        let mut binding = identity::EntryBinding {
            device,
            origin: policy.origin.clone(),
            room_id: policy.room_id.clone(),
            trust_id: policy.trust_id.clone(),
            policy_hash: policy.hash(),
            identity: client.identity.clone(),
            mls_key: B64.encode(client.signer.to_public_vec()),
            nonce: identity::hash(client.identity.as_bytes()),
            not_before: identity::now() - 1,
            not_after: identity::now() + 1200,
            signature: String::new(),
        };
        binding.signature = B64.encode(key.sign(&binding.message()).to_bytes());
        peers.push(Peer {
            identity: client.identity.clone(),
            public_key: binding.mls_key.clone(),
            key_package: package["key_package"].as_str().unwrap().to_string(),
            _name: String::new(),
            binding: Some(binding),
            offer: None,
            ready: None,
        });
    }
    let roster = identity::roster_hash(&peers).unwrap();
    for (client, peer) in clients.iter_mut().zip(&mut peers) {
        let mut offer = identity::RoundProof {
            group_id: group_id.into(),
            key_epoch: if staged { 1 } else { 0 },
            policy_hash: policy.hash(),
            roster_hash: roster.clone(),
            key_package_hash: identity::hash(&B64.decode(&peer.key_package).unwrap()),
            signature: String::new(),
        };
        offer.signature = B64.encode(client.signer.sign(&offer.message()).unwrap());
        peer.offer = Some(offer);
    }
    for client in clients.iter_mut() {
        request(client, json!({"operation":"approve", "group_id": group_id, "members":public(&peers), "authorization_hash":identity::hash(b"verified fixture roster")})).unwrap();
    }
    peers
}
fn public(peers: &[Peer]) -> Vec<Value> {
    peers.iter().map(|p| json!({"identity":p.identity,"public_key":p.public_key,"key_package":p.key_package,"binding":p.binding,"offer":p.offer})).collect()
}
fn bootstrap(clients: &mut [&mut Client], group_id: &str) -> (Vec<Peer>, String) {
    let peers = prepare(clients, group_id, false);
    let public = public(&peers);
    let created = request(
        clients[0],
        json!({"operation":"create", "group_id":group_id, "members":public}),
    )
    .unwrap();
    let welcome = created["welcome"].as_str().unwrap().to_string();
    for client in clients.iter_mut().skip(1) {
        let joined = request(
            client,
            json!({"operation":"join", "group_id":group_id, "members":public, "welcome":welcome}),
        )
        .unwrap();
        assert_eq!(created["confirmation"], joined["confirmation"]);
    }
    (peers, welcome)
}

fn encrypt(key: &[u8], payload: &[u8]) -> Vec<u8> {
    Aes256Gcm::new_from_slice(key)
        .unwrap()
        .encrypt(&Nonce::from([7u8; 12]), payload)
        .unwrap()
}
fn decrypt(key: &[u8], payload: &[u8]) -> bool {
    Aes256Gcm::new_from_slice(key)
        .unwrap()
        .decrypt(&Nonce::from([7u8; 12]), payload)
        .is_ok()
}

#[test]
fn real_mls_sender_separation_and_removed_member_isolation() {
    let mut a = Client::new("a.login_a").unwrap();
    let mut b = Client::new("b.login_b").unwrap();
    let mut c = Client::new("c.login_c").unwrap();
    bootstrap(&mut [&mut a, &mut b], "session/1");
    let old_a_key = b.media_key(&a.identity).unwrap();
    let old_ciphertext = encrypt(&old_a_key, b"old audio");
    assert!(decrypt(&a.media_key(&a.identity).unwrap(), &old_ciphertext));
    bootstrap(&mut [&mut a, &mut b, &mut c], "session/2");
    assert!(
        !decrypt(&c.media_key(&a.identity).unwrap(), &old_ciphertext),
        "joiner decrypted old audio"
    );
    let a_key = a.media_key(&a.identity).unwrap();
    assert_eq!(a_key, b.media_key(&a.identity).unwrap());
    assert_eq!(a_key, c.media_key(&a.identity).unwrap());
    assert_ne!(a_key, c.media_key(&c.identity).unwrap());
    let audio = encrypt(&a_key, b"sender A audio");
    assert!(
        !decrypt(&c.media_key(&c.identity).unwrap(), &audio),
        "sender keys were interchangeable"
    );
    let removed_b_key = b.media_key(&a.identity).unwrap();
    bootstrap(&mut [&mut a, &mut c], "session/3");
    let new_audio = encrypt(&a.media_key(&a.identity).unwrap(), b"audio after removal");
    assert!(
        !decrypt(&removed_b_key, &new_audio),
        "removed receiver decrypted new audio"
    );
    assert!(decrypt(&c.media_key(&a.identity).unwrap(), &new_audio));
    assert!(a.media_key(&b.identity).is_err());
    assert!(
        !decrypt(&a.media_key(&a.identity).unwrap(), &old_ciphertext),
        "later state recovered old audio"
    );
}

#[test]
fn admission_roster_binding_and_old_welcome_replay() {
    let mut a = Client::new("a.login_a").unwrap();
    let mut b = Client::new("b.login_b").unwrap();
    let (peers, welcome) = bootstrap(&mut [&mut a, &mut b], "session/1");
    request(&mut b, json!({"operation":"key_package"})).unwrap();
    let public = public(&peers);
    assert!(
        request(
            &mut b,
            json!({"operation":"join", "group_id":"session/1", "members":public, "welcome":welcome})
        )
        .is_err(),
        "old Welcome reused after fresh initialization"
    );
    let mut impostor = Client::new("b.login_b").unwrap();
    let impostor_package =
        request(&mut impostor, json!({"operation":"key_package"})).unwrap()["key_package"].clone();
    request(&mut a, json!({"operation":"key_package"})).unwrap();
    let altered = vec![
        json!({"identity":a.identity, "public_key":B64.encode(a.signer.to_public_vec()), "key_package":""}),
        json!({"identity":b.identity, "public_key":B64.encode(b.signer.to_public_vec()), "key_package":impostor_package}),
    ];
    assert!(
        request(
            &mut a,
            json!({"operation":"create", "group_id":"session/2", "members":altered})
        )
        .is_err(),
        "substituted signing key was admitted"
    );
    assert!(a.media_key(&a.identity).is_err());
}

#[test]
fn more_than_twenty_members_and_fresh_periodic_group() {
    let mut clients = (0..24)
        .map(|n| Client::new(&format!("member{n:02}.login")).unwrap())
        .collect::<Vec<_>>();
    bootstrap(&mut clients.iter_mut().collect::<Vec<_>>(), "twenty-four/1");
    let previous = clients[0].media_key(&clients[0].identity).unwrap();
    for client in &clients {
        assert_eq!(previous, client.media_key(&clients[0].identity).unwrap());
    }
    bootstrap(&mut clients.iter_mut().collect::<Vec<_>>(), "twenty-four/2");
    assert_ne!(
        previous,
        clients[0].media_key(&clients[0].identity).unwrap()
    );
    for client in &mut clients {
        client.clear_round();
        assert!(client.media_key("member00.login").is_err());
        assert!(client.provider.storage().values.read().unwrap().is_empty());
    }
}

#[test]
fn malformed_messages_fail_without_activating_group() {
    let mut client = Client::new("a.login").unwrap();
    request(&mut client, json!({"operation":"key_package"})).unwrap();
    for input in [String::new(), B64.encode([0u8; 512]), "!!!".into()] {
        assert!(request(
            &mut client,
            json!({"operation":"join", "group_id":"malformed", "members":[], "welcome":input})
        )
        .is_err());
        assert!(client.media_key("a.login").is_err());
    }
}

#[test]
fn compromised_server_cannot_substitute_verified_keys_or_add_an_invisible_receiver() {
    let mut a = Client::new("a.login").unwrap();
    let mut b = Client::new("b.login").unwrap();
    let mut hidden = Client::new("server.hidden").unwrap();
    let peers = prepare(&mut [&mut a, &mut b], "attack/1", false);
    let mut altered = public(&peers);
    altered[1]["public_key"] = json!(B64.encode(hidden.signer.to_public_vec()));
    assert!(request(
        &mut a,
        json!({"operation":"create","group_id":"attack/1","members":altered})
    )
    .is_err());
    assert!(a.media_key(&a.identity).is_err());
    // Even a correctly self-signed attacker certificate cannot enter a pinned
    // owner's whitelist. Renaming it to a verified routing identity is useless.
    let legitimate = a.trust.clone().unwrap();
    let mut rogue = prepare(&mut [&mut hidden], "attack/1", false);
    let binding = rogue[0].binding.as_mut().unwrap();
    binding.origin = legitimate.origin.clone();
    binding.room_id = legitimate.room_id.clone();
    binding.trust_id = legitimate.trust_id.clone();
    binding.policy_hash = legitimate.hash();
    let (key, _) = device(&hidden.identity);
    use ed25519_dalek::Signer;
    binding.signature = B64.encode(key.sign(&binding.message()).to_bytes());
    let mut injected = peers.clone();
    injected.push(rogue.remove(0));
    assert!(request(
        &mut a,
        json!({"operation":"create","group_id":"attack/1","members":public(&injected)})
    )
    .is_err());
    assert!(a.media_key(&a.identity).is_err());
    // Valid signatures from another group/epoch cannot be replayed into this
    // group, nor can a server strip V5 proofs and fall back to V3.
    assert!(request(
        &mut a,
        json!({"operation":"create","group_id":"attack/2","members":public(&peers)})
    )
    .is_err());
    let stripped = peers.iter().map(|p| json!({"identity":p.identity,"public_key":p.public_key,"key_package":p.key_package})).collect::<Vec<_>>();
    assert!(request(
        &mut a,
        json!({"operation":"create","group_id":"attack/1","members":stripped})
    )
    .is_err());
}

#[test]
fn staged_round_preserves_active_keys_and_identity_until_activation() {
    let mut a = Client::new("a.login").unwrap();
    let mut b = Client::new("b.login").unwrap();
    bootstrap(&mut [&mut a, &mut b], "membership/1");
    let old = a.media_key(&a.identity).unwrap();
    let public_key = a.signer.to_public_vec();
    let members = public(&prepare(&mut [&mut a, &mut b], "membership/1/key/1", true));
    assert_eq!(old, a.media_key(&a.identity).unwrap());
    let created = request(
        &mut a,
        json!({"operation":"staged_create","group_id":"membership/1/key/1","key_epoch":1,"members":members}),
    )
    .unwrap();
    let joined = request(&mut b, json!({"operation":"staged_join","group_id":"membership/1/key/1","key_epoch":1,"members":members,"welcome":created["welcome"]})).unwrap();
    assert_eq!(created["confirmation"], joined["confirmation"]);
    let identity = a.identity.clone();
    let next = a.with_staged(|client| client.media_key(&identity)).unwrap();
    assert_eq!(
        next,
        b.with_staged(|client| client.media_key(&identity)).unwrap()
    );
    assert_ne!(old, next);
    assert_eq!(old, a.media_key(&identity).unwrap());
    assert_eq!(public_key, a.signer.to_public_vec());
    assert!(request(
        &mut a,
        json!({"operation":"activate_staged","group_id":"wrong"})
    )
    .is_err());
    assert_eq!(old, a.media_key(&identity).unwrap());
    request(
        &mut a,
        json!({"operation":"activate_staged","group_id":"membership/1/key/1"}),
    )
    .unwrap();
    assert_eq!(next, a.media_key(&identity).unwrap());
    assert!(a.staged.is_none());
    assert!(request(
        &mut a,
        json!({"operation":"activate_staged","group_id":"membership/1"})
    )
    .is_err());
    b.clear_round();
    assert!(b.staged.is_none());
    assert!(b.media_key(&identity).is_err());
}

#[test]
fn discarding_or_rejecting_candidate_never_erases_active_round() {
    let mut a = Client::new("a.login").unwrap();
    bootstrap(&mut [&mut a], "active");
    let old = a.media_key(&a.identity).unwrap();
    request(&mut a, json!({"operation":"staged_key_package"})).unwrap();
    assert!(request(
        &mut a,
        json!({"operation":"staged_join","group_id":"bad","members":[],"welcome":"invalid"})
    )
    .is_err());
    assert_eq!(old, a.media_key(&a.identity).unwrap());
    request(&mut a, json!({"operation":"discard_staged"})).unwrap();
    assert!(a.staged.is_none());
    assert_eq!(old, a.media_key(&a.identity).unwrap());
}

#[test]
fn mutual_room_and_valid_certificates_do_not_replace_local_roster_approval() {
    let mut a = Client::new("a.login").unwrap();
    let mut b = Client::new("b.login").unwrap();
    let peers = prepare(&mut [&mut a, &mut b], "approval/1", false);
    a.approval = None;
    assert!(request(&mut a, json!({"operation":"create","group_id":"approval/1","members":public(&peers)})).is_err());
    assert!(a.media_key("a.login").is_err());
}

#[test]
fn media_export_stops_at_local_key_age_even_with_valid_identity() {
    let mut a = Client::new("a.login").unwrap();
    bootstrap(&mut [&mut a], "age/1");
    assert!(a.media_key("a.login").is_ok());
    a.created_at_ns = Some(continuous_ns().saturating_sub(120_000_000_000));
    assert!(a.authorized_until > identity::now());
    assert!(a.media_key("a.login").is_err());
    assert!(request(&mut a, json!({"operation":"lifetime"})).is_err());
}
