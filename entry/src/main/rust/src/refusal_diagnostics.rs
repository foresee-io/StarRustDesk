//! Server text is untrusted and may echo credentials. Only emit fixed reason codes.
pub(super) fn connection_code(reason: &str) -> i32 {
    match detail(reason) {
        "login_required" | "token_missing_or_required" | "authentication_required" => -25,
        "token_expired" | "token_invalid" => -26,
        "permission_denied" => -27,
        _ => -13,
    }
}

pub(super) fn detail(reason: &str) -> &'static str {
    let text = reason.to_lowercase();
    let has = |phrases: &[&str]| phrases.iter().any(|phrase| text.contains(phrase));
    if has(&["token expired", "expired token", "token has expired", "token is expired", "令牌已过期"]) {
        "token_expired"
    } else if has(&["invalid token", "token invalid", "token is invalid", "token not valid", "invalid access token", "无效令牌"]) {
        "token_invalid"
    } else if has(&["token required", "missing token", "token missing", "token is required", "token is empty", "empty token", "access token required"]) {
        "token_missing_or_required"
    } else if has(&["not logged in", "login required", "login first", "log in first", "please login", "please log in", "未登录", "请先登录"]) {
        "login_required"
    } else if has(&["authentication required", "authorization required", "requires authentication"]) {
        "authentication_required"
    } else if has(&["authentication failed", "failed to authenticate", "authentication failure", "invalid credentials", "unauthorized", "unauthenticated", "认证失败", "鉴权失败"]) {
        "authentication_failed"
    } else if has(&["permission denied", "access denied", "forbidden", "not allowed", "无权限", "权限不足"]) {
        "permission_denied"
    } else if has(&["key mismatch", "invalid key", "invalid license", "invalid licence", "key is invalid"]) {
        "server_key_invalid"
    } else if has(&["too many requests", "rate limit", "too frequent"]) {
        "rate_limited"
    } else {
        "unrecognized_redacted"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn distinguishes_authentication_reasons() {
        assert_eq!(connection_code("Please log in first"), -25);
        assert_eq!(connection_code("Token expired"), -26);
        assert_eq!(connection_code("Permission denied"), -27);
        assert_eq!(connection_code("unknown private information"), -13);
        for (text, expected) in [
            ("Invalid token", "token_invalid"),
            ("Access token is required", "token_missing_or_required"),
            ("Token has expired", "token_expired"),
            ("Please log in first", "login_required"),
            ("Authentication required", "authentication_required"),
            ("Failed to authenticate", "authentication_failed"),
            ("Permission denied", "permission_denied"),
            ("Key mismatch", "server_key_invalid"),
            ("Too many requests", "rate_limited"),
        ] {
            assert_eq!(detail(text), expected);
        }
    }

    #[test]
    fn never_returns_raw_server_text_or_echoed_secrets() {
        assert_eq!(detail("Invalid token: eyJ-private-token\r\n[I] forged-log"), "token_invalid");
        assert_eq!(detail("password=private-password id=123456789 https://private.test"), "unrecognized_redacted");
        assert_eq!(detail("认证失败：secret-value"), "authentication_failed");
        assert_eq!(detail(&"x".repeat(100_000)), "unrecognized_redacted");
        assert_eq!(detail(""), "unrecognized_redacted");
    }
}
