use crate::media::Provider;
use serde::{Deserialize, Serialize};

/// Provider-neutral account state carried over the native JSON boundary.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderAccountState {
    pub provider: Provider,
    pub linked: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub picture_url: Option<String>,
}

/// A native shell can render this challenge regardless of the provider that
/// produced it. Secret exchange and persistence remain platform-owned.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceAuthorizationChallenge {
    pub provider: Provider,
    pub user_code: String,
    pub verification_uri: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verification_uri_complete: Option<String>,
    pub expires_in: u64,
    pub interval: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCredentialHandle {
    pub provider: Provider,
    pub handle: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_challenge_has_a_stable_cross_platform_wire_shape() {
        let challenge = DeviceAuthorizationChallenge {
            provider: Provider::YouTube,
            user_code: "ABC-DEF".into(),
            verification_uri: "https://example.test/device".into(),
            verification_uri_complete: None,
            expires_in: 900,
            interval: 5,
        };
        let value = serde_json::to_value(challenge).unwrap();
        assert_eq!(value["provider"], "youtube");
        assert_eq!(value["userCode"], "ABC-DEF");
        assert_eq!(value["expiresIn"], 900);
    }
}
