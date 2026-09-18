use axum::{
    body::Body,
    extract::Request,
    http::{HeaderMap, HeaderValue},
};
use http::header::HeaderName;

static HEADER_TARGET_WORKER: HeaderName = HeaderName::from_static("x-smg-target-worker");
static HEADER_ROUTING_KEY: HeaderName = HeaderName::from_static("x-smg-routing-key");
// 09-16 session-aware routing: CC/Anthropic clients carry a stable session id.
static HEADER_CC_SESSION_ID: HeaderName = HeaderName::from_static("x-claude-code-session-id");

// 09-16: synthesized content-key window. A conversation prompt only grows at the
// tail each turn, so the leading window is invariant across turns -> same key.
const CONTENT_KEY_WINDOW: usize = 8192;

fn extract_header_value<'a>(headers: Option<&'a HeaderMap>, name: &HeaderName) -> Option<&'a str> {
    headers
        .and_then(|h| h.get(name))
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty())
}

pub fn extract_target_worker(headers: Option<&HeaderMap>) -> Option<&str> {
    extract_header_value(headers, &HEADER_TARGET_WORKER)
}

pub fn extract_routing_key(headers: Option<&HeaderMap>) -> Option<&str> {
    // 09-16: header-based key ladder (tier 1: explicit, tier 2: CC/Anthropic session id).
    // Borrowed, no allocation. This is the subset the per-card LoadGuard can see.
    extract_header_value(headers, &HEADER_ROUTING_KEY)
        .or_else(|| extract_header_value(headers, &HEADER_CC_SESSION_ID))
}

/// Tier 3: synthesize a stable content routing key from the first 8192 chars of the
/// request text. Same conversation -> same leading window -> same key -> same card.
/// Returns None when there is no usable text.
pub fn synthesize_content_key(request_text: Option<&str>) -> Option<String> {
    let text = request_text?.trim();
    if text.is_empty() {
        return None;
    }
    let window: String = text.chars().take(CONTENT_KEY_WINDOW).collect();
    Some(format!("c:{:x}", xxhash_rust::xxh3::xxh3_64(window.as_bytes())))
}

/// Full routing-key ladder: explicit header -> CC session header -> synthesized
/// content key -> None. Returns an owned String (synthesis allocates).
pub fn resolve_routing_key(
    headers: Option<&HeaderMap>,
    request_text: Option<&str>,
) -> Option<String> {
    extract_routing_key(headers)
        .map(str::to_owned)
        .or_else(|| synthesize_content_key(request_text))
}

/// Copy request headers to a Vec of name-value string pairs
/// Used for forwarding headers to backend workers
pub fn copy_request_headers(req: &Request<Body>) -> Vec<(String, String)> {
    req.headers()
        .iter()
        .filter_map(|(name, value)| {
            // Convert header value to string, skipping non-UTF8 headers
            value
                .to_str()
                .ok()
                .map(|v| (name.to_string(), v.to_string()))
        })
        .collect()
}

/// Convert headers from reqwest Response to axum HeaderMap
/// Filters out hop-by-hop headers that shouldn't be forwarded
pub fn preserve_response_headers(reqwest_headers: &HeaderMap) -> HeaderMap {
    let mut headers = HeaderMap::new();

    for (name, value) in reqwest_headers.iter() {
        // Skip hop-by-hop headers that shouldn't be forwarded
        // Use eq_ignore_ascii_case to avoid string allocation
        if should_forward_header_no_alloc(name.as_str()) {
            // The original name and value are already valid, so we can just clone them
            headers.insert(name.clone(), value.clone());
        }
    }

    headers
}

/// Determine if a header should be forwarded without allocating (case-insensitive)
fn should_forward_header_no_alloc(name: &str) -> bool {
    // List of headers that should NOT be forwarded (hop-by-hop headers)
    // Use eq_ignore_ascii_case to avoid to_lowercase() allocation
    !(name.eq_ignore_ascii_case("connection")
        || name.eq_ignore_ascii_case("keep-alive")
        || name.eq_ignore_ascii_case("proxy-authenticate")
        || name.eq_ignore_ascii_case("proxy-authorization")
        || name.eq_ignore_ascii_case("te")
        || name.eq_ignore_ascii_case("trailers")
        || name.eq_ignore_ascii_case("transfer-encoding")
        || name.eq_ignore_ascii_case("upgrade")
        || name.eq_ignore_ascii_case("content-encoding")
        || name.eq_ignore_ascii_case("host"))
}

/// Apply headers to a reqwest request builder, filtering out headers that shouldn't be forwarded
/// or that will be set automatically by reqwest
pub fn apply_request_headers(
    headers: &HeaderMap,
    mut request_builder: reqwest::RequestBuilder,
    skip_content_headers: bool,
) -> reqwest::RequestBuilder {
    // Always forward Authorization header first if present
    if let Some(auth) = headers
        .get("authorization")
        .or_else(|| headers.get("Authorization"))
    {
        request_builder = request_builder.header("Authorization", auth.clone());
    }

    // Forward other headers, filtering out problematic ones
    // Use eq_ignore_ascii_case to avoid to_lowercase() allocation per header
    for (key, value) in headers.iter() {
        let key_str = key.as_str();

        // Skip headers that:
        // - Are set automatically by reqwest (content-type, content-length for POST/PUT)
        // - We already handled (authorization)
        // - Are hop-by-hop headers (connection, transfer-encoding)
        // - Should not be forwarded (host)
        let should_skip = key_str.eq_ignore_ascii_case("authorization") // Already handled above
            || key_str.eq_ignore_ascii_case("host")
            || key_str.eq_ignore_ascii_case("connection")
            || key_str.eq_ignore_ascii_case("transfer-encoding")
            || key_str.eq_ignore_ascii_case("keep-alive")
            || key_str.eq_ignore_ascii_case("te")
            || key_str.eq_ignore_ascii_case("trailers")
            || key_str.eq_ignore_ascii_case("accept-encoding")
            || key_str.eq_ignore_ascii_case("upgrade")
            || (skip_content_headers
                && (key_str.eq_ignore_ascii_case("content-type")
                    || key_str.eq_ignore_ascii_case("content-length")));

        if !should_skip {
            request_builder = request_builder.header(key.clone(), value.clone());
        }
    }

    request_builder
}

/// API provider types for provider-specific header handling
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiProvider {
    Anthropic,
    Xai,
    OpenAi,
    Gemini,
    Generic,
}

impl ApiProvider {
    /// Detect provider type from URL
    pub fn from_url(url: &str) -> Self {
        if url.contains("anthropic") {
            ApiProvider::Anthropic
        } else if url.contains("x.ai") {
            ApiProvider::Xai
        } else if url.contains("openai.com") {
            ApiProvider::OpenAi
        } else if url.contains("googleapis.com") {
            ApiProvider::Gemini
        } else {
            ApiProvider::Generic
        }
    }
}

/// Apply provider-specific headers to request
pub fn apply_provider_headers(
    mut req: reqwest::RequestBuilder,
    url: &str,
    auth_header: Option<&HeaderValue>,
) -> reqwest::RequestBuilder {
    let provider = ApiProvider::from_url(url);

    match provider {
        ApiProvider::Anthropic => {
            // Anthropic requires x-api-key instead of Authorization
            // Extract Bearer token and use as x-api-key
            if let Some(auth) = auth_header {
                if let Ok(auth_str) = auth.to_str() {
                    let api_key = auth_str.strip_prefix("Bearer ").unwrap_or(auth_str);
                    req = req
                        .header("x-api-key", api_key)
                        .header("anthropic-version", "2023-06-01");
                }
            }
        }
        ApiProvider::Gemini | ApiProvider::Xai | ApiProvider::OpenAi | ApiProvider::Generic => {
            // Standard OpenAI-compatible: use Authorization header as-is
            if let Some(auth) = auth_header {
                req = req.header("Authorization", auth);
            }
        }
    }

    req
}

/// Extract auth header with passthrough semantics.
///
/// Passthrough mode: User's Authorization header takes priority.
/// Fallback: Worker's API key is used only if user didn't provide auth.
///
/// This enables use cases where:
/// 1. Users send their own API keys (multi-tenant, BYOK)
/// 2. Router has a default key for users who don't provide one
pub fn extract_auth_header(
    headers: Option<&HeaderMap>,
    worker_api_key: &Option<String>,
) -> Option<HeaderValue> {
    // Passthrough: Try user's auth header first
    let user_auth = headers.and_then(|h| {
        h.get("authorization")
            .or_else(|| h.get("Authorization"))
            .cloned()
    });

    // Return user's auth if provided, otherwise use worker's API key
    user_auth.or_else(|| {
        worker_api_key
            .as_ref()
            .and_then(|k| HeaderValue::from_str(&format!("Bearer {}", k)).ok())
    })
}

#[inline]
pub fn should_forward_request_header(name: &str) -> bool {
    const REQUEST_ID_PREFIX: &str = "x-request-id-";

    name.eq_ignore_ascii_case("authorization")
        || name.eq_ignore_ascii_case("x-request-id")
        || name.eq_ignore_ascii_case("x-correlation-id")
        || name.eq_ignore_ascii_case("traceparent")
        || name.eq_ignore_ascii_case("tracestate")
        || name.eq_ignore_ascii_case("x-smg-routing-key")
        || name
            .get(..REQUEST_ID_PREFIX.len())
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case(REQUEST_ID_PREFIX))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_header_value_returns_value() {
        let mut headers = HeaderMap::new();
        headers.insert("x-smg-routing-key", "test-key".parse().unwrap());
        assert_eq!(extract_routing_key(Some(&headers)), Some("test-key"));
    }

    #[test]
    fn test_extract_header_value_returns_none_for_missing() {
        let headers = HeaderMap::new();
        assert_eq!(extract_routing_key(Some(&headers)), None);
    }

    #[test]
    fn test_extract_header_value_returns_none_for_empty() {
        let mut headers = HeaderMap::new();
        headers.insert("x-smg-routing-key", "".parse().unwrap());
        assert_eq!(extract_routing_key(Some(&headers)), None);
    }

    #[test]
    fn test_extract_header_value_returns_none_for_none_headers() {
        assert_eq!(extract_routing_key(None), None);
    }

    // 09-16: CC session id is tier-2 of the key ladder
    #[test]
    fn test_extract_routing_key_cc_session_id() {
        let mut headers = HeaderMap::new();
        headers.insert("x-claude-code-session-id", "00148b6c-uuid".parse().unwrap());
        assert_eq!(
            extract_routing_key(Some(&headers)),
            Some("00148b6c-uuid")
        );
    }

    #[test]
    fn test_extract_routing_key_explicit_beats_cc_session() {
        let mut headers = HeaderMap::new();
        headers.insert("x-smg-routing-key", "explicit".parse().unwrap());
        headers.insert("x-claude-code-session-id", "sess-uuid".parse().unwrap());
        assert_eq!(extract_routing_key(Some(&headers)), Some("explicit"));
    }

    // 09-16: synthesized content key
    #[test]
    fn test_synthesize_content_key_same_text_same_key() {
        let a = synthesize_content_key(Some("system prompt + user turn one"));
        let b = synthesize_content_key(Some("system prompt + user turn one"));
        assert_eq!(a, b);
        assert!(a.is_some());
    }

    #[test]
    fn test_synthesize_content_key_diff_text_diff_key() {
        let a = synthesize_content_key(Some("conversation alpha"));
        let b = synthesize_content_key(Some("conversation beta"));
        assert_ne!(a, b);
    }

    #[test]
    fn test_synthesize_content_key_none_for_empty() {
        assert_eq!(synthesize_content_key(None), None);
        assert_eq!(synthesize_content_key(Some("")), None);
        assert_eq!(synthesize_content_key(Some("   \n  ")), None);
    }

    #[test]
    fn test_synthesize_content_key_window_stability() {
        // 09-16: a conversation grows at the tail; once the leading 8192-char
        // window is full, appending more text must NOT change the key.
        let base: String = std::iter::repeat('x').take(9000).collect();
        let k1 = synthesize_content_key(Some(base.as_str()));
        let k2 = synthesize_content_key(Some(&format!("{} more tail", base)));
        assert_eq!(k1, k2);
    }

    #[test]
    fn test_resolve_routing_key_ladder() {
        // tier 1: explicit header wins
        let mut headers = HeaderMap::new();
        headers.insert("x-smg-routing-key", "e1".parse().unwrap());
        headers.insert("x-claude-code-session-id", "s1".parse().unwrap());
        assert_eq!(resolve_routing_key(Some(&headers), Some("text")), Some("e1".to_string()));

        // tier 2: CC session header
        let mut headers2 = HeaderMap::new();
        headers2.insert("x-claude-code-session-id", "s2".parse().unwrap());
        assert_eq!(resolve_routing_key(Some(&headers2), Some("text")), Some("s2".to_string()));

        // tier 3: synthesized from text
        let key = resolve_routing_key(None, Some("only text here"));
        assert!(key.as_ref().unwrap().starts_with("c:"));

        // tier 4: none
        assert_eq!(resolve_routing_key(None, None), None);
    }

    #[test]
    fn test_extract_target_worker() {
        let mut headers = HeaderMap::new();
        headers.insert("x-smg-target-worker", "2".parse().unwrap());
        assert_eq!(extract_target_worker(Some(&headers)), Some("2"));
    }

    #[test]
    fn test_extract_target_worker_missing() {
        let headers = HeaderMap::new();
        assert_eq!(extract_target_worker(Some(&headers)), None);
    }

    #[test]
    fn test_should_forward_request_header_whitelist() {
        assert!(should_forward_request_header("authorization"));
        assert!(should_forward_request_header("Authorization"));
        assert!(should_forward_request_header("AUTHORIZATION"));
        assert!(should_forward_request_header("x-request-id"));
        assert!(should_forward_request_header("X-Request-Id"));
        assert!(should_forward_request_header("x-correlation-id"));
        assert!(should_forward_request_header("X-Correlation-ID"));
        assert!(should_forward_request_header("traceparent"));
        assert!(should_forward_request_header("Traceparent"));
        assert!(should_forward_request_header("tracestate"));
        assert!(should_forward_request_header("Tracestate"));
        assert!(should_forward_request_header("x-request-id-user"));
        assert!(should_forward_request_header("X-Request-ID-Span"));
        assert!(should_forward_request_header("x-request-id-123"));
        assert!(should_forward_request_header("x-smg-routing-key"));
        assert!(should_forward_request_header("X-SMG-Routing-Key"));
    }

    #[test]
    fn test_should_forward_request_header_blocked() {
        assert!(!should_forward_request_header("content-type"));
        assert!(!should_forward_request_header("Content-Type"));
        assert!(!should_forward_request_header("content-length"));
        assert!(!should_forward_request_header("host"));
        assert!(!should_forward_request_header("Host"));
        assert!(!should_forward_request_header("connection"));
        assert!(!should_forward_request_header("transfer-encoding"));
        assert!(!should_forward_request_header("accept"));
        assert!(!should_forward_request_header("accept-encoding"));
        assert!(!should_forward_request_header("user-agent"));
        assert!(!should_forward_request_header("cookie"));
        assert!(!should_forward_request_header("x-custom-header"));
        assert!(!should_forward_request_header("x-api-key"));
    }
}
