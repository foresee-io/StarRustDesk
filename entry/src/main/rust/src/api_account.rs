//! Volatile account authorization, never stored in hbb_common configuration.
use super::*;

#[derive(serde::Deserialize, Default)]
struct AccountContext {
    token: String,
    rendezvous: String,
    key: String,
}

impl AccountContext {
    fn matches(&self, server: &str, key: &str) -> bool {
        !server.trim().is_empty() && !self.rendezvous.trim().is_empty()
            && !self.key.is_empty() && self.key == key
            && default_rendezvous_addr(server) == default_rendezvous_addr(&self.rendezvous)
    }
}
static ACCOUNT: Mutex<Option<AccountContext>> = Mutex::new(None);

#[no_mangle]
pub extern "C" fn rust_set_api_account_context(json: *const c_char) -> i32 {
    let Some(json) = cstr_to_string(json) else { return -1; };
    let Ok(mut account) = ACCOUNT.lock() else { return -1; };
    *account = None;
    if json.is_empty() { return 0; }
    if json.len() > 32768 { return -1; }
    let Ok(context) = serde_json::from_str::<AccountContext>(&json) else { return -1; };
    if context.token.is_empty() || context.token.len() > 16384
        || context.token.chars().any(char::is_control)
        || context.rendezvous.trim().is_empty() || context.rendezvous.len() > 1024
        || get_rs_pk(&context.key).is_none() { return -1; }
    *account = Some(context);
    0
}

pub(super) fn token_for(server: &str, key: &str) -> String {
    ACCOUNT.lock().ok().and_then(|account| account.as_ref()
        .filter(|a| a.matches(server, key)).map(|a| a.token.clone())).unwrap_or_default()
}

pub(super) fn attach(request: &mut RendezvousMessage, token: &str) {
    if let Some(rendezvous_message::Union::PunchHoleRequest(punch)) = request.union.as_mut() {
        punch.token = token.to_string();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn account_binding_never_follows_network_or_key_changes() {
        let account = AccountContext { token: "test-token".into(), rendezvous: "id.example.test".into(), key: "key-a".into() };
        assert!(account.matches("id.example.test:21116", "key-a"));
        assert!(!account.matches("other.example.test", "key-a"));
        assert!(!account.matches("id.example.test", "key-b"));
        assert!(!account.matches("", "key-a"));
        let mut request = punch_hole_request("123", "key-a", ConnType::DEFAULT_CONN, false,
            NatType::UNKNOWN_NAT, 0, Vec::new(), String::new());
        attach(&mut request, "test-token");
        assert_eq!(request.punch_hole_request().token, "test-token");
    }
}
