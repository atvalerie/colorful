#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Transport {
    LanDirect,
    InternetDirect,
    Relay,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct NetworkObservation {
    pub same_lan: bool,
    pub direct_candidate_succeeded: bool,
    pub relay_available: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ConnectivityPolicy {
    pub allow_relay: bool,
}

impl Default for ConnectivityPolicy {
    fn default() -> Self {
        Self { allow_relay: true }
    }
}

impl ConnectivityPolicy {
    pub fn choose(self, observation: NetworkObservation) -> Transport {
        if observation.same_lan {
            Transport::LanDirect
        } else if observation.direct_candidate_succeeded {
            Transport::InternetDirect
        } else if self.allow_relay && observation.relay_available {
            Transport::Relay
        } else {
            Transport::Unavailable
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direct_lan_wins_over_every_other_path() {
        let transport = ConnectivityPolicy::default().choose(NetworkObservation {
            same_lan: true,
            direct_candidate_succeeded: true,
            relay_available: true,
        });
        assert_eq!(transport, Transport::LanDirect);
    }

    #[test]
    fn relay_handles_failed_nat_traversal() {
        let transport = ConnectivityPolicy::default().choose(NetworkObservation {
            relay_available: true,
            ..NetworkObservation::default()
        });
        assert_eq!(transport, Transport::Relay);
    }

    #[test]
    fn relay_can_be_disabled_for_strict_device_only_mode() {
        let transport = ConnectivityPolicy { allow_relay: false }.choose(NetworkObservation {
            relay_available: true,
            ..NetworkObservation::default()
        });
        assert_eq!(transport, Transport::Unavailable);
    }
}
