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
    fn server_matches(&self, server: &str, public_server: bool) -> bool {
        if self.rendezvous == "@public" {
            public_server && rendezvous_candidates("").iter().any(|candidate|
                default_rendezvous_addr(candidate) == default_rendezvous_addr(server))
        } else {
            !public_server && !server.trim().is_empty() && !self.rendezvous.trim().is_empty()
                && default_rendezvous_addr(server) == default_rendezvous_addr(&self.rendezvous)
        }
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
    let Ok(mut context) = serde_json::from_str::<AccountContext>(&json) else { return -1; };
    if context.rendezvous == "@public" {
        if !context.key.is_empty() { return -1; }
        context.key = RS_PUB_KEY.to_string();
    }
    if context.token.is_empty() || context.token.len() > 16384
        || context.token.chars().any(char::is_control)
        || context.rendezvous.trim().is_empty() || context.rendezvous.len() > 1024
        || get_rs_pk(&context.key).is_none() { return -1; }
    *account = Some(context);
    0
}

pub(super) fn token_for(server: &str, key: &str, public_server: bool) -> String {
    // Diagnose the same snapshot used for selection, never the token itself.
    let (token, diagnostic) = match ACCOUNT.lock() {
        Ok(account) => select_token_for_network(account.as_ref(), server, key, public_server),
        Err(_) => (String::new(), "context=unavailable token_selected=false".to_string()),
    };
    emit_event(&format!("account auth selection {diagnostic}"));
    token
}

fn select_token(account: Option<&AccountContext>, server: &str, key: &str) -> (String, String) {
    select_token_for_network(account, server, key, false)
}

fn select_token_for_network(account: Option<&AccountContext>, server: &str, key: &str, public_server: bool) -> (String, String) {
    let Some(account) = account else {
        return (String::new(), "context=absent token_selected=false".to_string());
    };
    let server_match = account.server_matches(server, public_server);
    let key_match = !account.key.is_empty() && account.key == key;
    let selected = server_match && key_match && !account.token.is_empty();
    (if selected { account.token.clone() } else { String::new() }, format!(
        "context=present server_match={server_match} key_match={key_match} token_present={} token_selected={selected}",
        !account.token.is_empty()))
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
    fn public_tokens_require_public_network_and_builtin_key() {
        let account = AccountContext { token: "secret".into(), rendezvous: "@public".into(), key: RS_PUB_KEY.into() };
        let server = default_rendezvous_addr("");
        assert_eq!(select_token_for_network(Some(&account), &server, RS_PUB_KEY, true).0, "secret");
        assert!(select_token_for_network(Some(&account), &server, RS_PUB_KEY, false).0.is_empty());
        assert!(select_token_for_network(Some(&account), "evil.test", RS_PUB_KEY, true).0.is_empty());
        assert!(select_token_for_network(Some(&account), &server, "other-key", true).0.is_empty());
    }
    #[test]
    fn selection_diagnostics_are_consistent_and_secret_free() {
        let account = AccountContext { token: "private-token".into(), rendezvous: "private.test".into(), key: "private-key".into() };
        for (server, key, selected) in [
            ("private.test:21116", "private-key", true),
            ("other.test", "private-key", false),
            ("private.test", "wrong-key", false),
            ("", "private-key", false),
        ] {
            let (token, diagnostic) = select_token(Some(&account), server, key);
            assert_eq!(!token.is_empty(), selected);
            assert!(diagnostic.contains(&format!("token_selected={selected}")));
            for secret in ["private-token", "private.test", "private-key", "other.test", "wrong-key"] {
                assert!(!diagnostic.contains(secret));
            }
        }
        assert!(select_token(Some(&account), "other.test", "private-key").1.contains("server_match=false key_match=true"));
        assert!(select_token(Some(&account), "private.test", "wrong-key").1.contains("server_match=true key_match=false"));
        assert_eq!(select_token(None, "private.test", "private-key").1, "context=absent token_selected=false");
    }
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
