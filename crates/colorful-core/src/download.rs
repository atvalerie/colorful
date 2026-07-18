use crate::media::MediaId;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum DownloadState {
    Queued,
    Resolving,
    Downloading,
    Complete,
    Failed,
    Paused,
}

impl DownloadState {
    pub(crate) fn wire_name(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Resolving => "resolving",
            Self::Downloading => "downloading",
            Self::Complete => "complete",
            Self::Failed => "failed",
            Self::Paused => "paused",
        }
    }

    pub(crate) fn from_wire_name(value: &str) -> Option<Self> {
        match value {
            "queued" => Some(Self::Queued),
            "resolving" => Some(Self::Resolving),
            "downloading" => Some(Self::Downloading),
            "complete" => Some(Self::Complete),
            "failed" => Some(Self::Failed),
            "paused" => Some(Self::Paused),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadJob {
    pub media_id: MediaId,
    pub state: DownloadState,
    pub local_path: Option<String>,
    pub bytes_downloaded: u64,
    pub bytes_total: Option<u64>,
    pub source_expires_at_ms: Option<i64>,
    pub error_code: Option<String>,
    pub updated_at_ms: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DownloadTransitionError {
    AlreadyComplete,
    InvalidProgress,
    MissingLocalPath,
}

impl DownloadJob {
    pub fn queued(media_id: MediaId, updated_at_ms: i64) -> Self {
        Self {
            media_id,
            state: DownloadState::Queued,
            local_path: None,
            bytes_downloaded: 0,
            bytes_total: None,
            source_expires_at_ms: None,
            error_code: None,
            updated_at_ms,
        }
    }

    pub fn begin_resolving(&mut self, updated_at_ms: i64) -> Result<(), DownloadTransitionError> {
        self.ensure_not_complete()?;
        self.state = DownloadState::Resolving;
        self.error_code = None;
        self.source_expires_at_ms = None;
        self.updated_at_ms = updated_at_ms;
        Ok(())
    }

    pub fn begin_transfer(
        &mut self,
        bytes_total: Option<u64>,
        source_expires_at_ms: Option<i64>,
        updated_at_ms: i64,
    ) -> Result<(), DownloadTransitionError> {
        self.ensure_not_complete()?;
        if bytes_total.is_some_and(|total| self.bytes_downloaded > total) {
            return Err(DownloadTransitionError::InvalidProgress);
        }
        self.state = DownloadState::Downloading;
        self.bytes_total = bytes_total;
        self.source_expires_at_ms = source_expires_at_ms;
        self.error_code = None;
        self.updated_at_ms = updated_at_ms;
        Ok(())
    }

    pub fn report_progress(
        &mut self,
        bytes_downloaded: u64,
        updated_at_ms: i64,
    ) -> Result<(), DownloadTransitionError> {
        self.ensure_not_complete()?;
        if bytes_downloaded < self.bytes_downloaded
            || self
                .bytes_total
                .is_some_and(|total| bytes_downloaded > total)
        {
            return Err(DownloadTransitionError::InvalidProgress);
        }
        self.state = DownloadState::Downloading;
        self.bytes_downloaded = bytes_downloaded;
        self.updated_at_ms = updated_at_ms;
        Ok(())
    }

    pub fn pause(&mut self, updated_at_ms: i64) -> Result<(), DownloadTransitionError> {
        self.ensure_not_complete()?;
        self.state = DownloadState::Paused;
        self.updated_at_ms = updated_at_ms;
        Ok(())
    }

    pub fn fail(
        &mut self,
        code: impl Into<String>,
        updated_at_ms: i64,
    ) -> Result<(), DownloadTransitionError> {
        self.ensure_not_complete()?;
        self.state = DownloadState::Failed;
        self.error_code = Some(code.into());
        self.updated_at_ms = updated_at_ms;
        Ok(())
    }

    pub fn complete(
        &mut self,
        local_path: impl Into<String>,
        size_bytes: u64,
        updated_at_ms: i64,
    ) -> Result<(), DownloadTransitionError> {
        self.ensure_not_complete()?;
        let local_path = local_path.into();
        if local_path.trim().is_empty() {
            return Err(DownloadTransitionError::MissingLocalPath);
        }
        if self.bytes_total.is_some_and(|total| size_bytes != total) {
            return Err(DownloadTransitionError::InvalidProgress);
        }
        self.state = DownloadState::Complete;
        self.local_path = Some(local_path);
        self.bytes_downloaded = size_bytes;
        self.bytes_total = Some(size_bytes);
        self.source_expires_at_ms = None;
        self.error_code = None;
        self.updated_at_ms = updated_at_ms;
        Ok(())
    }

    fn ensure_not_complete(&self) -> Result<(), DownloadTransitionError> {
        if self.state == DownloadState::Complete {
            Err(DownloadTransitionError::AlreadyComplete)
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::Provider;

    #[test]
    fn download_progress_is_monotonic_and_completion_is_terminal() {
        let mut job = DownloadJob::queued(MediaId::new(Provider::Tidal, "42").unwrap(), 1);
        job.begin_resolving(2).unwrap();
        job.begin_transfer(Some(100), Some(9000), 3).unwrap();
        job.report_progress(40, 4).unwrap();
        assert_eq!(
            job.report_progress(39, 5),
            Err(DownloadTransitionError::InvalidProgress)
        );
        job.pause(6).unwrap();
        job.begin_transfer(Some(100), Some(10_000), 7).unwrap();
        job.complete("audio/42.flac", 100, 8).unwrap();
        assert_eq!(job.pause(9), Err(DownloadTransitionError::AlreadyComplete));
    }
}
