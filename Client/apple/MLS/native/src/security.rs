use super::{identity, recovery, Result, B64};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use vodozemac::{
    sas::{EstablishedSas, Mac, Sas},
    Curve25519PublicKey,
};
use zeroize::Zeroizing;

// Best-effort clearing of the native JSON copies. The UI also releases its
// temporary strings; neither layer promises forensic memory erasure.
struct SecretRequest(Value);
pub(super) fn clear_json(v: &mut Value) {
    use zeroize::Zeroize;
    match v {
        Value::String(s) => s.zeroize(),
        Value::Array(a) => a.iter_mut().for_each(clear_json),
        Value::Object(o) => o.values_mut().for_each(clear_json),
        _ => {}
    }
}
impl Drop for SecretRequest {
    fn drop(&mut self) {
        clear_json(&mut self.0);
    }
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", deny_unknown_fields)]
enum Packet {
    Request { commitment: String },
    Accept { key: String },
    Key { key: String },
    Mac { mac: String },
    Cancel,
}
struct Verification {
    context: String,
    initiator: bool,
    ephemeral: Option<Sas>,
    established: Option<EstablishedSas>,
    commitment: String,
    local_confirmed: bool,
    remote_confirmed: bool,
    expires: u64,
}
#[derive(Default)]
pub struct Security {
    sessions: BTreeMap<String, Verification>,
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v.get(key)
        .and_then(Value::as_str)
        .ok_or("missing security parameter")
}
fn commit(context: &str, key: &str) -> String {
    identity::hash(&identity::message(
        "Chirp SAS commitment v1",
        &[context.as_bytes(), key.as_bytes()],
    ))
}
impl Security {
    pub fn call(&mut self, v: Value) -> Result<Value> {
        let request = SecretRequest(v);
        let v = &request.0;
        let operation = text(&v, "action")?;
        if operation == "encrypt" {
            let password = Zeroizing::new(text(&v, "password")?.to_owned());
            let payload = Zeroizing::new(text(&v, "payload")?.to_owned());
            return Ok(json!({"file":B64.encode(recovery::encrypt(&payload,&password)?)}));
        }
        if operation == "decrypt" {
            let password = Zeroizing::new(text(&v, "password")?.to_owned());
            let file = B64
                .decode(text(&v, "file")?)
                .map_err(|_| "invalid recovery encoding")?;
            let payload = recovery::decrypt(&file, &password)?;
            return Ok(json!({"payload":*payload}));
        }
        self.sessions.retain(|_, s| s.expires > identity::now());
        let id = text(&v, "id")?.to_owned();
        if id.is_empty() || id.len() > 128 {
            return Err("invalid SAS transaction");
        }
        if operation == "sas_cancel" {
            self.sessions.remove(&id);
            return Ok(
                json!({"message":serde_json::to_string(&Packet::Cancel).map_err(|_|"SAS serialization failed")?}),
            );
        }
        if operation == "sas_start" || operation == "sas_accept" {
            if self.sessions.len() >= 16 || self.sessions.contains_key(&id) {
                return Err("SAS transaction exists");
            }
            let context = text(&v, "context")?.to_owned();
            if context.len() > 8192 || context.is_empty() {
                return Err("invalid SAS context");
            }
            let ephemeral = Sas::new();
            let public = ephemeral.public_key().to_base64();
            let initiator = operation == "sas_start";
            let commitment = if initiator {
                commit(&context, &public)
            } else {
                text(&v, "commitment")?.to_owned()
            };
            let packet = if initiator {
                Packet::Request {
                    commitment: commitment.clone(),
                }
            } else {
                Packet::Accept { key: public }
            };
            self.sessions.insert(
                id,
                Verification {
                    context,
                    initiator,
                    ephemeral: Some(ephemeral),
                    established: None,
                    commitment,
                    local_confirmed: false,
                    remote_confirmed: false,
                    expires: identity::now() + 600,
                },
            );
            return Ok(
                json!({"message":serde_json::to_string(&packet).map_err(|_|"SAS serialization failed")?}),
            );
        }
        // Any protocol error destroys this ephemeral state; callers must start a
        // fresh transaction rather than continue a partially checked transcript.
        let mut session = self
            .sessions
            .remove(&id)
            .ok_or("SAS transaction missing or expired")?;
        let mut response = json!({});
        if operation == "sas_receive" {
            let packet: Packet =
                serde_json::from_str(text(&v, "message")?).map_err(|_| "invalid SAS message")?;
            match packet {
                Packet::Accept { key } if session.initiator && session.ephemeral.is_some() => {
                    let ephemeral = session.ephemeral.take().ok_or("SAS state invalid")?;
                    let public = ephemeral.public_key().to_base64();
                    let remote =
                        Curve25519PublicKey::from_base64(&key).map_err(|_| "invalid SAS key")?;
                    session.established = Some(
                        ephemeral
                            .diffie_hellman(remote)
                            .map_err(|_| "invalid SAS shared secret")?,
                    );
                    response["message"] =
                        json!(serde_json::to_string(&Packet::Key { key: public })
                            .map_err(|_| "SAS serialization failed")?);
                }
                Packet::Key { key } if !session.initiator && session.ephemeral.is_some() => {
                    if commit(&session.context, &key) != session.commitment {
                        return Err("SAS commitment mismatch");
                    }
                    let remote =
                        Curve25519PublicKey::from_base64(&key).map_err(|_| "invalid SAS key")?;
                    session.established = Some(
                        session
                            .ephemeral
                            .take()
                            .ok_or("SAS state invalid")?
                            .diffie_hellman(remote)
                            .map_err(|_| "invalid SAS shared secret")?,
                    );
                }
                Packet::Mac { mac }
                    if session.established.is_some() && !session.remote_confirmed =>
                {
                    let sas = session.established.as_ref().ok_or("SAS state invalid")?;
                    let label = if session.initiator {
                        "Chirp SAS responder identity confirmation v1"
                    } else {
                        "Chirp SAS initiator identity confirmation v1"
                    };
                    sas.verify_mac(
                        &session.context,
                        label,
                        &Mac::from_base64(&mac).map_err(|_| "invalid SAS MAC")?,
                    )
                    .map_err(|_| "SAS identity confirmation failed")?;
                    session.remote_confirmed = true;
                }
                Packet::Cancel => return Ok(json!({"cancelled":true})),
                _ => return Err("unexpected or replayed SAS message"),
            }
        } else if operation == "sas_confirm" {
            let sas = session
                .established
                .as_ref()
                .ok_or("SAS code not available")?;
            if session.local_confirmed {
                return Err("SAS already confirmed");
            }
            session.local_confirmed = true;
            let label = if session.initiator {
                "Chirp SAS initiator identity confirmation v1"
            } else {
                "Chirp SAS responder identity confirmation v1"
            };
            response["message"] = json!(serde_json::to_string(&Packet::Mac {
                mac: sas.calculate_mac(&session.context, label).to_base64()
            })
            .map_err(|_| "SAS serialization failed")?);
        } else {
            return Err("unknown security action");
        }
        if let Some(sas) = &session.established {
            // vodozemac's full default decimal representation: three 13-bit
            // groups. Never truncate to one four-digit number.
            let (a, b, c) = sas.bytes(&session.context).decimals();
            response["decimals"] = json!([a, b, c]);
        }
        let complete = session.local_confirmed && session.remote_confirmed;
        response["complete"] = json!(complete);
        if !complete {
            self.sessions.insert(id, session);
        }
        Ok(response)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn message(v: &Value) -> String {
        v["message"].as_str().unwrap().to_owned()
    }
    #[test]
    fn full_handshake_requires_both_confirmation_macs() {
        let mut a = Security::default();
        let mut b = Security::default();
        let request=a.call(json!({"action":"sas_start","id":"test","context":"session|Alice-root-device|Bob-root-device"})).unwrap();
        let commitment: Value = serde_json::from_str(&message(&request)).unwrap();
        let accept=b.call(json!({"action":"sas_accept","id":"test","context":"session|Alice-root-device|Bob-root-device","commitment":commitment["commitment"]})).unwrap();
        let reveal = a
            .call(json!({"action":"sas_receive","id":"test","message":message(&accept)}))
            .unwrap();
        let bob = b
            .call(json!({"action":"sas_receive","id":"test","message":message(&reveal)}))
            .unwrap();
        assert_eq!(reveal["decimals"], bob["decimals"]);
        let mac_a = a.call(json!({"action":"sas_confirm","id":"test"})).unwrap();
        assert_eq!(mac_a["complete"], false);
        let received = b
            .call(json!({"action":"sas_receive","id":"test","message":message(&mac_a)}))
            .unwrap();
        assert_eq!(received["complete"], false);
        let mac_b = b.call(json!({"action":"sas_confirm","id":"test"})).unwrap();
        assert_eq!(mac_b["complete"], true);
        assert_eq!(
            a.call(json!({"action":"sas_receive","id":"test","message":message(&mac_b)}))
                .unwrap()["complete"],
            true
        );
        assert!(a
            .call(json!({"action":"sas_receive","id":"test","message":message(&mac_b)}))
            .is_err());
    }
    #[test]
    fn commitment_identity_context_and_reflection_attacks_abort() {
        let mut alice = Security::default();
        let mut bob = Security::default();
        let request=alice.call(json!({"action":"sas_start","id":"attack","context":"Alice-root-device|Bob-root-device|room-session"})).unwrap();
        let packet: Value = serde_json::from_str(&message(&request)).unwrap();
        let accept=bob.call(json!({"action":"sas_accept","id":"attack","context":"Alice-root-device|Other-root-device|room-session","commitment":packet["commitment"]})).unwrap();
        let reveal = alice
            .call(json!({"action":"sas_receive","id":"attack","message":message(&accept)}))
            .unwrap();
        assert!(bob
            .call(json!({"action":"sas_receive","id":"attack","message":message(&reveal)}))
            .is_err());
        assert!(bob
            .call(json!({"action":"sas_confirm","id":"attack"}))
            .is_err());
        let own_mac = alice
            .call(json!({"action":"sas_confirm","id":"attack"}))
            .unwrap();
        assert!(alice
            .call(json!({"action":"sas_receive","id":"attack","message":message(&own_mac)}))
            .is_err());
        assert!(alice
            .call(json!({"action":"sas_confirm","id":"attack"}))
            .is_err());
    }
}
