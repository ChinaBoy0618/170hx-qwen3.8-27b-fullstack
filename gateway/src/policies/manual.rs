//! Manual routing policy based on routing key header
//!
//! This policy provides sticky session routing where each unique routing key
//! is consistently mapped to the same worker. Unlike consistent hashing,
//! this policy:
//! - Does NOT redistribute any sessions when workers are added
//! - Only remaps sessions when their assigned worker becomes unhealthy
//! - Maintains up to 2 candidate workers per routing key for fast failover
//!
//! Use this when you need stronger stickiness guarantees than consistent hashing,
//! for example with stateful chat sessions where context is stored on the worker.
//!
//! ## Header
//! - `X-SMG-Routing-Key`: The routing key for sticky session routing

use std::{
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock},
    time::Instant,
};

use async_trait::async_trait;
use dashmap::{mapref::entry::Entry, DashMap};
use rand::Rng;
use tracing::{info, warn};

use super::{
    get_healthy_worker_indices, utils::PeriodicTask, LoadBalancingPolicy, SelectWorkerInfo,
};
use crate::{
    config::ManualAssignmentMode, core::Worker, observability::metrics::Metrics,
    routers::header_utils::resolve_routing_key,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ExecutionBranch {
    NoHealthyWorkers,
    OccupiedHit,
    OccupiedMiss,
    Vacant,
    NoRoutingId,
}

impl ExecutionBranch {
    fn as_str(&self) -> &'static str {
        match self {
            Self::NoHealthyWorkers => "no_healthy_workers",
            Self::OccupiedHit => "occupied_hit",
            Self::OccupiedMiss => "occupied_miss",
            Self::Vacant => "vacant",
            Self::NoRoutingId => "no_routing_id",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct RoutingId(String);

impl RoutingId {
    fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }
}

const MAX_CANDIDATE_WORKERS: usize = 2;

#[derive(Debug, Clone)]
pub struct ManualConfig {
    pub eviction_interval_secs: u64,
    pub max_idle_secs: u64,
    pub assignment_mode: ManualAssignmentMode,
    /// 09-16: optional on-disk path for the routing_map (sticky session table).
    /// When set, the table is loaded at startup and snapshotted on every TTL
    /// eviction cycle, so a gateway restart restores in-flight sessions to
    /// their original worker (no re-prefill).
    pub routing_map_file: Option<PathBuf>,
}

impl Default for ManualConfig {
    fn default() -> Self {
        Self {
            eviction_interval_secs: 60,
            max_idle_secs: 4 * 3600,
            assignment_mode: ManualAssignmentMode::Random,
            routing_map_file: None,
        }
    }
}

#[derive(Debug, Clone)]
struct Node {
    candi_worker_urls: Vec<String>,
    last_access: Instant,
}

impl Node {
    fn push_bounded(&mut self, url: String) {
        while self.candi_worker_urls.len() >= MAX_CANDIDATE_WORKERS {
            self.candi_worker_urls.remove(0);
        }
        self.candi_worker_urls.push(url);
    }
}

#[derive(Debug)]
pub struct ManualPolicy {
    routing_map: Arc<DashMap<RoutingId, Node>>,
    assignment_mode: ManualAssignmentMode,
    _eviction_task: Option<PeriodicTask>,
}

// 09-17: process-wide lock so concurrent ManualPolicyEviction threads can't
// race on the same .tmp file (each cycle: write(tmp) + rename(tmp->path)).
// Without this, IGW mode can spawn >1 ManualPolicy, each with its own
// PeriodicTask, and one thread's rename can fire while another's tmp is in
// flight -> ENOENT in rename -> spurious WARN every cycle.
static SNAPSHOT_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

// 09-17: process-wide routing_map. Without this, IGW mode can spawn >1
// ManualPolicy instance (one per worker registration), each with its own
// DashMap, so the PeriodicTask snapshotting an empty DashMap sees entries={}
// while the metrics counter reports the busy instance's entries=6+. Sharing
// one map also makes the lock+rename serialization actually meaningful.
fn shared_routing_map() -> Arc<DashMap<RoutingId, Node>> {
    static M: OnceLock<Arc<DashMap<RoutingId, Node>>> = OnceLock::new();
    M.get_or_init(|| Arc::new(DashMap::new())).clone()
}

impl Default for ManualPolicy {
    fn default() -> Self {
        Self::new()
    }
}

impl ManualPolicy {
    pub fn new() -> Self {
        Self::with_config(ManualConfig::default())
    }

    pub fn with_config(config: ManualConfig) -> Self {
        use std::time::Duration;

        // 09-17: share a single process-wide map so all ManualPolicy
        // instances (one per IGW worker registration) see the same entries.
        let routing_map = shared_routing_map();

        // 09-16: restore the sticky session table from disk (gateway restart
        // recovery). Restored entries get a fresh last_access so the 4h TTL
        // starts now; stale worker URLs self-heal on first request
        // (find_healthy_worker URL match fails -> OccupiedMiss -> re-select).
        if let Some(ref path) = config.routing_map_file {
            Self::load_routing_map(&routing_map, path);
        }

        let eviction_task = if config.eviction_interval_secs > 0 && config.max_idle_secs > 0 {
            let routing_map_clone = Arc::clone(&routing_map);
            let max_idle = Duration::from_secs(config.max_idle_secs);
            // 09-16: move the persistence path into the periodic closure so
            // every TTL cycle also refreshes the on-disk snapshot.
            let persist_path = config.routing_map_file.clone();

            Some(PeriodicTask::spawn(
                config.eviction_interval_secs,
                "ManualPolicyEviction",
                move || {
                    let now = Instant::now();
                    let before_size = routing_map_clone.len();

                    routing_map_clone
                        .retain(|_, node| now.duration_since(node.last_access) < max_idle);

                    let evicted_count = before_size - routing_map_clone.len();
                    if evicted_count > 0 {
                        info!(
                            "ManualPolicy TTL eviction: evicted {} entries, remaining {} (max_idle: {}s)",
                            evicted_count,
                            routing_map_clone.len(),
                            max_idle.as_secs()
                        );
                    }

                    // 09-16: snapshot after eviction so the file never holds
                    // entries the policy has already dropped.
                    if let Some(ref p) = persist_path {
                        Self::snapshot_routing_map(&routing_map_clone, p);
                    }
                },
            ))
        } else {
            None
        };

        Self {
            routing_map,
            assignment_mode: config.assignment_mode,
            _eviction_task: eviction_task,
        }
    }

    /// 09-16: load the persisted routing table. Tolerant on purpose — a bad or
    /// missing file must never take the gateway down (warn + start empty).
    fn load_routing_map(routing_map: &DashMap<RoutingId, Node>, path: &PathBuf) {
        let content = match std::fs::read_to_string(path) {
            Ok(c) => c,
            Err(e) => {
                // Missing file on first boot is normal; anything else is suspicious.
                if path.exists() {
                    warn!(
                        "ManualPolicy persistence: failed to read {}: {} — starting with empty table",
                        path.display(),
                        e
                    );
                }
                return;
            }
        };

        #[derive(serde::Deserialize)]
        struct PersistedTable {
            #[serde(default)]
            version: u32,
            #[serde(default)]
            entries: std::collections::BTreeMap<String, Vec<String>>,
        }

        let table: PersistedTable = match serde_json::from_str(&content) {
            Ok(t) => t,
            Err(e) => {
                warn!(
                    "ManualPolicy persistence: malformed {} ({}), backing it up and starting empty",
                    path.display(),
                    e
                );
                let backup = path.with_extension("corrupt");
                if let Err(be) = std::fs::rename(path, &backup) {
                    warn!(
                        "ManualPolicy persistence: could not back up corrupt file to {}: {}",
                        backup.display(),
                        be
                    );
                }
                return;
            }
        };

        let now = Instant::now();
        let restored = table
            .entries
            .into_iter()
            .filter(|(_, urls)| !urls.is_empty())
            .map(|(key, urls)| {
                (
                    RoutingId::new(key),
                    Node {
                        candi_worker_urls: urls,
                        last_access: now,
                    },
                )
            });
        let mut count = 0;
        for (k, v) in restored {
            routing_map.insert(k, v);
            count += 1;
        }
        info!(
            "ManualPolicy persistence: restored {} sticky session entries from {}",
            count,
            path.display()
        );
    }

    /// 09-16: write the current routing table to disk (atomic: tmp + rename).
    /// Only the periodic task writes, so no locking is needed.
    fn snapshot_routing_map(routing_map: &DashMap<RoutingId, Node>, path: &PathBuf) {
        let entries: std::collections::BTreeMap<String, Vec<String>> = routing_map
            .iter()
            .map(|e| (e.key().0.clone(), e.value().candi_worker_urls.clone()))
            .collect();
        let payload = serde_json::json!({ "version": 1, "entries": entries });
        let json = match serde_json::to_string(&payload) {
            Ok(j) => j,
            Err(e) => {
                warn!("ManualPolicy persistence: serialize failed: {}", e);
                return;
            }
        };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let tmp = path.with_extension("json.tmp");
        // 09-17: process-wide lock so two ManualPolicyEviction threads (which
        // exist when IGW mode re-registers workers and a second ManualPolicy
        // gets built) can't race on the same .tmp file.
        let lock = SNAPSHOT_LOCK.get_or_init(|| Mutex::new(()));
        let _guard = lock.lock().unwrap_or_else(|p| p.into_inner());
        match std::fs::write(&tmp, json) {
            Ok(()) => {
                if let Err(e) = std::fs::rename(&tmp, path) {
                    warn!(
                        "ManualPolicy persistence: rename({} -> {}) failed: {} (kind={:?}, tmp_exists_before_rename={})",
                        tmp.display(),
                        path.display(),
                        e,
                        e.kind(),
                        tmp.exists(),
                    );
                }
            }
            Err(e) => {
                warn!(
                    "ManualPolicy persistence: write({}) failed: {} (kind={:?}, path_exists={}, parent_exists={})",
                    tmp.display(),
                    e,
                    e.kind(),
                    path.exists(),
                    path.parent().map(|p| p.exists()).unwrap_or(false),
                );
            }
        }
    }

    fn select_new_worker(&self, workers: &[Arc<dyn Worker>], healthy_indices: &[usize]) -> usize {
        match self.assignment_mode {
            ManualAssignmentMode::Random => random_select(healthy_indices),
            ManualAssignmentMode::MinLoad => min_load_select(workers, healthy_indices),
            ManualAssignmentMode::MinGroup => min_group_select(workers, healthy_indices),
        }
    }

    fn select_by_routing_id(
        &self,
        workers: &[Arc<dyn Worker>],
        routing_id: &str,
        healthy_indices: &[usize],
    ) -> (usize, ExecutionBranch) {
        let routing_id = RoutingId::new(routing_id);

        match self.routing_map.entry(routing_id) {
            Entry::Occupied(mut entry) => {
                let node = entry.get_mut();
                node.last_access = Instant::now();
                if let Some(idx) =
                    find_healthy_worker(&node.candi_worker_urls, workers, healthy_indices)
                {
                    (idx, ExecutionBranch::OccupiedHit)
                } else {
                    let selected_idx = self.select_new_worker(workers, healthy_indices);
                    node.push_bounded(workers[selected_idx].url().to_string());
                    (selected_idx, ExecutionBranch::OccupiedMiss)
                }
            }
            Entry::Vacant(entry) => {
                let selected_idx = self.select_new_worker(workers, healthy_indices);
                entry.insert(Node {
                    candi_worker_urls: vec![workers[selected_idx].url().to_string()],
                    last_access: Instant::now(),
                });
                (selected_idx, ExecutionBranch::Vacant)
            }
        }
    }

    fn select_worker_impl(
        &self,
        workers: &[Arc<dyn Worker>],
        info: &SelectWorkerInfo<'_>,
    ) -> (Option<usize>, ExecutionBranch) {
        let healthy_indices = get_healthy_worker_indices(workers);
        if healthy_indices.is_empty() {
            return (None, ExecutionBranch::NoHealthyWorkers);
        }

        // 09-16: full key ladder — explicit header -> CC session id -> synthesized
        // content key. Requests that still have no key (rare) go to the
        // least-loaded worker instead of random, so even keyless traffic spreads.
        if let Some(routing_id) = resolve_routing_key(info.headers, info.request_text) {
            let (idx, branch) = self.select_by_routing_id(workers, &routing_id, &healthy_indices);
            return (Some(idx), branch);
        }

        (
            Some(min_load_select(workers, &healthy_indices)),
            ExecutionBranch::NoRoutingId,
        )
    }
}

#[async_trait]
impl LoadBalancingPolicy for ManualPolicy {
    async fn select_worker(
        &self,
        workers: &[Arc<dyn Worker>],
        info: &SelectWorkerInfo<'_>,
    ) -> Option<usize> {
        let (result, branch) = self.select_worker_impl(workers, info);
        Metrics::record_worker_manual_policy_branch(branch.as_str());
        Metrics::set_manual_policy_cache_entries(self.routing_map.len());
        result
    }

    fn name(&self) -> &'static str {
        "manual"
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

fn find_healthy_worker(
    urls: &[String],
    workers: &[Arc<dyn Worker>],
    healthy_indices: &[usize],
) -> Option<usize> {
    for url in urls {
        if let Some(idx) = find_worker_index_by_url(workers, url) {
            if healthy_indices.contains(&idx) {
                return Some(idx);
            }
        }
    }
    None
}

fn find_worker_index_by_url(workers: &[Arc<dyn Worker>], url: &str) -> Option<usize> {
    workers.iter().position(|w| w.url() == url)
}

fn random_select(healthy_indices: &[usize]) -> usize {
    let mut rng = rand::rng();
    let random_idx = rng.random_range(0..healthy_indices.len());
    healthy_indices[random_idx]
}

fn select_min_by<K, V, F>(indices: &[K], get_value: F) -> K
where
    K: Copy,
    V: Ord,
    F: Fn(K) -> V,
{
    let mut min_val: Option<V> = None;
    let mut candidates = Vec::new();

    for &idx in indices {
        let val = get_value(idx);
        match min_val.as_ref().map(|m| val.cmp(m)) {
            None | Some(std::cmp::Ordering::Less) => {
                min_val = Some(val);
                candidates.clear();
                candidates.push(idx);
            }
            Some(std::cmp::Ordering::Equal) => {
                candidates.push(idx);
            }
            Some(std::cmp::Ordering::Greater) => {}
        }
    }

    if candidates.len() == 1 {
        candidates[0]
    } else {
        let mut rng = rand::rng();
        candidates[rng.random_range(0..candidates.len())]
    }
}

fn min_load_select(workers: &[Arc<dyn Worker>], healthy_indices: &[usize]) -> usize {
    select_min_by(healthy_indices, |idx| workers[idx].load())
}

fn min_group_select(workers: &[Arc<dyn Worker>], healthy_indices: &[usize]) -> usize {
    select_min_by(healthy_indices, |idx| {
        workers[idx].worker_routing_key_load().value()
    })
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use crate::core::{BasicWorkerBuilder, WorkerType};

    fn create_workers(urls: &[&str]) -> Vec<Arc<dyn Worker>> {
        urls.iter()
            .map(|url| {
                Arc::new(
                    BasicWorkerBuilder::new(*url)
                        .worker_type(WorkerType::Regular)
                        .build(),
                ) as Arc<dyn Worker>
            })
            .collect()
    }

    fn headers_with_routing_key(key: &str) -> http::HeaderMap {
        let mut headers = http::HeaderMap::new();
        headers.insert("x-smg-routing-key", key.parse().unwrap());
        headers
    }

    #[test]
    fn test_manual_consistent_routing() {
        let policy = ManualPolicy::new();
        let workers = create_workers(&["http://w1:8000", "http://w2:8000", "http://w3:8000"]);

        let headers = headers_with_routing_key("user-123");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };

        let (first_result, branch) = policy.select_worker_impl(&workers, &info);
        let first_idx = first_result.unwrap();
        assert_eq!(branch, ExecutionBranch::Vacant);

        for _ in 0..10 {
            let (result, branch) = policy.select_worker_impl(&workers, &info);
            assert_eq!(
                result,
                Some(first_idx),
                "Same routing_id should route to same worker"
            );
            assert_eq!(branch, ExecutionBranch::OccupiedHit);
        }
    }

    #[test]
    fn test_manual_different_routing_ids() {
        let policy = ManualPolicy::new();
        let workers = create_workers(&["http://w1:8000", "http://w2:8000", "http://w3:8000"]);

        let mut distribution = HashMap::new();
        for i in 0..100 {
            let headers = headers_with_routing_key(&format!("user-{}", i));
            let info = SelectWorkerInfo {
                headers: Some(&headers),
                ..Default::default()
            };
            let (result, branch) = policy.select_worker_impl(&workers, &info);
            assert_eq!(branch, ExecutionBranch::Vacant);
            *distribution.entry(result.unwrap()).or_insert(0) += 1;
        }

        assert!(
            distribution.len() > 1,
            "Should distribute across multiple workers"
        );
    }

    #[test]
    fn test_manual_fallback_random() {
        let policy = ManualPolicy::new();
        let workers = create_workers(&["http://w1:8000", "http://w2:8000"]);

        let mut counts = HashMap::new();
        for _ in 0..100 {
            let info = SelectWorkerInfo::default();
            let (result, branch) = policy.select_worker_impl(&workers, &info);
            assert_eq!(branch, ExecutionBranch::NoRoutingId);
            if let Some(idx) = result {
                *counts.entry(idx).or_insert(0) += 1;
            }
        }

        assert_eq!(counts.len(), 2, "Random fallback should use all workers");
    }

    #[test]
    fn test_manual_with_unhealthy_workers() {
        let policy = ManualPolicy::new();
        let workers = create_workers(&["http://w1:8000", "http://w2:8000"]);

        workers[0].set_healthy(false);

        let headers = headers_with_routing_key("test-routing-id");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };

        let (result, branch) = policy.select_worker_impl(&workers, &info);
        assert_eq!(result, Some(1), "Should only select healthy worker");
        assert_eq!(branch, ExecutionBranch::Vacant);

        for _ in 0..10 {
            let (result, branch) = policy.select_worker_impl(&workers, &info);
            assert_eq!(result, Some(1), "Should only select healthy worker");
            assert_eq!(branch, ExecutionBranch::OccupiedHit);
        }
    }

    #[test]
    fn test_manual_no_healthy_workers() {
        let policy = ManualPolicy::new();
        let workers = create_workers(&["http://w1:8000"]);

        workers[0].set_healthy(false);
        let headers = headers_with_routing_key("test");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };
        let (result, branch) = policy.select_worker_impl(&workers, &info);
        assert_eq!(result, None);
        assert_eq!(branch, ExecutionBranch::NoHealthyWorkers);
    }

    #[test]
    fn test_manual_empty_routing_id() {
        let policy = ManualPolicy::new();
        let workers = create_workers(&["http://w1:8000", "http://w2:8000"]);

        let mut counts = HashMap::new();
        for _ in 0..100 {
            let headers = headers_with_routing_key("");
            let info = SelectWorkerInfo {
                headers: Some(&headers),
                ..Default::default()
            };
            let (result, branch) = policy.select_worker_impl(&workers, &info);
            assert_eq!(branch, ExecutionBranch::NoRoutingId);
            if let Some(idx) = result {
                *counts.entry(idx).or_insert(0) += 1;
            }
        }

        assert_eq!(
            counts.len(),
            2,
            "Empty routing_id should use random fallback"
        );
    }

    #[test]
    fn test_manual_remaps_when_worker_becomes_unhealthy() {
        let policy = ManualPolicy::new();
        let workers = create_workers(&["http://w1:8000", "http://w2:8000"]);

        let headers = headers_with_routing_key("sticky-user");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };

        let (first_result, branch) = policy.select_worker_impl(&workers, &info);
        let first_idx = first_result.unwrap();
        assert_eq!(branch, ExecutionBranch::Vacant);

        workers[first_idx].set_healthy(false);

        let (new_result, branch) = policy.select_worker_impl(&workers, &info);
        let new_idx = new_result.unwrap();
        assert_ne!(new_idx, first_idx, "Should remap to healthy worker");
        assert_eq!(branch, ExecutionBranch::OccupiedMiss);

        for _ in 0..10 {
            let (result, branch) = policy.select_worker_impl(&workers, &info);
            assert_eq!(
                result,
                Some(new_idx),
                "Should consistently route to new worker"
            );
            assert_eq!(branch, ExecutionBranch::OccupiedHit);
        }
    }

    #[test]
    fn test_manual_empty_workers() {
        let policy = ManualPolicy::new();
        let workers: Vec<Arc<dyn Worker>> = vec![];
        let headers = headers_with_routing_key("test");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };
        let (result, branch) = policy.select_worker_impl(&workers, &info);
        assert_eq!(result, None);
        assert_eq!(branch, ExecutionBranch::NoHealthyWorkers);
    }

    #[test]
    fn test_manual_single_worker() {
        let policy = ManualPolicy::new();
        let workers = create_workers(&["http://w1:8000"]);

        let headers = headers_with_routing_key("single-test");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };

        let (result, branch) = policy.select_worker_impl(&workers, &info);
        assert_eq!(result, Some(0));
        assert_eq!(branch, ExecutionBranch::Vacant);

        for _ in 0..10 {
            let (result, branch) = policy.select_worker_impl(&workers, &info);
            assert_eq!(result, Some(0));
            assert_eq!(branch, ExecutionBranch::OccupiedHit);
        }
    }

    #[test]
    fn test_manual_worker_recovery() {
        let policy = ManualPolicy::new();
        let workers = create_workers(&["http://w1:8000", "http://w2:8000"]);

        let headers = headers_with_routing_key("recovery-test");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };

        let (first_result, branch) = policy.select_worker_impl(&workers, &info);
        let first_idx = first_result.unwrap();
        assert_eq!(branch, ExecutionBranch::Vacant);

        workers[first_idx].set_healthy(false);

        let (second_result, branch) = policy.select_worker_impl(&workers, &info);
        let second_idx = second_result.unwrap();
        assert_ne!(second_idx, first_idx);
        assert_eq!(branch, ExecutionBranch::OccupiedMiss);

        workers[first_idx].set_healthy(true);

        let (after_recovery, branch) = policy.select_worker_impl(&workers, &info);
        assert_eq!(
            after_recovery,
            Some(first_idx),
            "Should return to original worker after recovery since it's first in candidate list"
        );
        assert_eq!(branch, ExecutionBranch::OccupiedHit);
    }

    #[test]
    fn test_manual_max_candidate_workers_eviction() {
        let policy = ManualPolicy::new();
        let workers = create_workers(&["http://w1:8000", "http://w2:8000", "http://w3:8000"]);

        let headers = headers_with_routing_key("eviction-test");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };

        let (first_result, branch) = policy.select_worker_impl(&workers, &info);
        let first_idx = first_result.unwrap();
        assert_eq!(branch, ExecutionBranch::Vacant);

        workers[first_idx].set_healthy(false);

        let (second_result, branch) = policy.select_worker_impl(&workers, &info);
        let second_idx = second_result.unwrap();
        assert_ne!(second_idx, first_idx);
        assert_eq!(branch, ExecutionBranch::OccupiedMiss);

        workers[second_idx].set_healthy(false);

        let remaining_idx = (0..3).find(|&i| i != first_idx && i != second_idx).unwrap();
        let (third_result, branch) = policy.select_worker_impl(&workers, &info);
        assert_eq!(
            third_result,
            Some(remaining_idx),
            "Should select the only remaining healthy worker"
        );
        assert_eq!(branch, ExecutionBranch::OccupiedMiss);

        workers[first_idx].set_healthy(true);

        let (idx_after_restore, branch) = policy.select_worker_impl(&workers, &info);
        assert_ne!(
            idx_after_restore,
            Some(first_idx),
            "First worker should be evicted from candidates due to MAX_CANDIDATE_WORKERS=2"
        );
        assert_eq!(branch, ExecutionBranch::OccupiedHit);
    }

    #[test]
    fn test_manual_policy_name() {
        let policy = ManualPolicy::new();
        assert_eq!(policy.name(), "manual");
    }

    #[test]
    fn test_manual_routing_info_push_bounded() {
        let mut info = Node {
            candi_worker_urls: vec!["http://w1:8000".to_string()],
            last_access: Instant::now(),
        };

        info.push_bounded("http://w2:8000".to_string());
        assert_eq!(info.candi_worker_urls.len(), 2);
        assert_eq!(info.candi_worker_urls[0], "http://w1:8000");
        assert_eq!(info.candi_worker_urls[1], "http://w2:8000");

        info.push_bounded("http://w3:8000".to_string());
        assert_eq!(info.candi_worker_urls.len(), 2);
        assert_eq!(
            info.candi_worker_urls[0], "http://w2:8000",
            "Oldest entry should be removed"
        );
        assert_eq!(info.candi_worker_urls[1], "http://w3:8000");
    }

    #[test]
    fn test_manual_find_healthy_worker_priority() {
        let workers = create_workers(&["http://w1:8000", "http://w2:8000", "http://w3:8000"]);

        let urls = vec![
            "http://w1:8000".to_string(),
            "http://w2:8000".to_string(),
            "http://w3:8000".to_string(),
        ];
        let healthy_indices = vec![0, 1, 2];

        let result = find_healthy_worker(&urls, &workers, &healthy_indices);
        assert_eq!(
            result,
            Some(0),
            "Should return first healthy worker in urls"
        );

        workers[0].set_healthy(false);
        let healthy_indices = vec![1, 2];
        let result = find_healthy_worker(&urls, &workers, &healthy_indices);
        assert_eq!(result, Some(1), "Should skip unhealthy and return next");

        workers[1].set_healthy(false);
        let healthy_indices = vec![2];
        let result = find_healthy_worker(&urls, &workers, &healthy_indices);
        assert_eq!(result, Some(2), "Should return last healthy worker");

        workers[2].set_healthy(false);
        let healthy_indices: Vec<usize> = vec![];
        let result = find_healthy_worker(&urls, &workers, &healthy_indices);
        assert_eq!(result, None, "Should return None when no healthy workers");
    }

    #[test]
    fn test_manual_find_worker_index_by_url() {
        let workers = create_workers(&["http://w1:8000", "http://w2:8000"]);

        assert_eq!(
            find_worker_index_by_url(&workers, "http://w1:8000"),
            Some(0)
        );
        assert_eq!(
            find_worker_index_by_url(&workers, "http://w2:8000"),
            Some(1)
        );
        assert_eq!(
            find_worker_index_by_url(&workers, "http://w3:8000"),
            None,
            "Should return None for unknown URL"
        );
    }

    #[test]
    fn test_manual_config_default() {
        let config = ManualConfig::default();
        assert_eq!(config.eviction_interval_secs, 60);
        assert_eq!(config.max_idle_secs, 4 * 3600);
    }

    #[test]
    fn test_manual_with_disabled_eviction() {
        let config = ManualConfig {
            eviction_interval_secs: 0,
            max_idle_secs: 3600,
            assignment_mode: ManualAssignmentMode::Random,
            routing_map_file: None,
        };
        let policy = ManualPolicy::with_config(config);
        assert!(policy._eviction_task.is_none());
    }

    #[test]
    fn test_manual_last_access_updates() {
        let policy = ManualPolicy::new();
        let workers = create_workers(&["http://w1:8000", "http://w2:8000"]);
        let headers = headers_with_routing_key("test-key");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };
        let routing_id = RoutingId::new("test-key");

        // Vacant: first access
        let (result, branch) = policy.select_worker_impl(&workers, &info);
        assert_eq!(branch, ExecutionBranch::Vacant);
        let first_idx = result.unwrap();
        let access_after_vacant = policy.routing_map.get(&routing_id).unwrap().last_access;
        assert!(access_after_vacant.elapsed().as_millis() < 100);

        std::thread::sleep(std::time::Duration::from_millis(10));

        // OccupiedHit: same worker still healthy
        let (_, branch) = policy.select_worker_impl(&workers, &info);
        assert_eq!(branch, ExecutionBranch::OccupiedHit);
        let access_after_hit = policy.routing_map.get(&routing_id).unwrap().last_access;
        assert!(access_after_hit > access_after_vacant);

        std::thread::sleep(std::time::Duration::from_millis(10));

        // OccupiedMiss: worker becomes unhealthy
        workers[first_idx].set_healthy(false);
        let (_, branch) = policy.select_worker_impl(&workers, &info);
        assert_eq!(branch, ExecutionBranch::OccupiedMiss);
        let access_after_miss = policy.routing_map.get(&routing_id).unwrap().last_access;
        assert!(access_after_miss > access_after_hit);
    }

    #[test]
    fn test_manual_ttl_eviction_logic() {
        use std::time::Duration;

        let config = ManualConfig {
            eviction_interval_secs: 2,
            max_idle_secs: 2,
            assignment_mode: ManualAssignmentMode::Random,
            routing_map_file: None,
        };
        let policy = ManualPolicy::with_config(config);
        let workers = create_workers(&["http://w1:8000", "http://w2:8000"]);

        let headers = headers_with_routing_key("key-0");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };
        policy.select_worker_impl(&workers, &info);

        assert_eq!(policy.routing_map.len(), 1);

        std::thread::sleep(Duration::from_secs(4));

        assert_eq!(policy.routing_map.len(), 0);
    }

    #[test]
    fn test_min_group_select_distributes_evenly() {
        let config = ManualConfig {
            assignment_mode: ManualAssignmentMode::MinGroup,
            ..Default::default()
        };
        let policy = ManualPolicy::with_config(config);
        let workers = create_workers(&["http://w1:8000", "http://w2:8000", "http://w3:8000"]);

        for i in 0..9 {
            let routing_key = format!("key-{}", i);
            let headers = headers_with_routing_key(&routing_key);
            let info = SelectWorkerInfo {
                headers: Some(&headers),
                ..Default::default()
            };

            let (result, branch) = policy.select_worker_impl(&workers, &info);
            assert!(result.is_some());
            assert_eq!(branch, ExecutionBranch::Vacant);

            let selected_idx = result.unwrap();
            workers[selected_idx]
                .worker_routing_key_load()
                .increment(&routing_key);
        }

        let distribution: HashMap<_, usize> = policy
            .routing_map
            .iter()
            .map(|e| e.candi_worker_urls.first().unwrap().clone())
            .fold(HashMap::new(), |mut acc, url| {
                *acc.entry(url).or_default() += 1;
                acc
            });

        assert_eq!(distribution.len(), 3, "Should use all 3 workers");
        for count in distribution.values() {
            assert_eq!(*count, 3, "Each worker should have exactly 3 routing keys");
        }
    }

    #[test]
    fn test_min_group_select_prefers_worker_with_fewer_routing_keys() {
        let config = ManualConfig {
            assignment_mode: ManualAssignmentMode::MinGroup,
            ..Default::default()
        };
        let policy = ManualPolicy::with_config(config);
        let workers = create_workers(&["http://w1:8000", "http://w2:8000", "http://w3:8000"]);

        workers[0].worker_routing_key_load().increment("existing-1");
        workers[0].worker_routing_key_load().increment("existing-2");
        workers[1].worker_routing_key_load().increment("existing-3");

        assert_eq!(workers[0].worker_routing_key_load().value(), 2);
        assert_eq!(workers[1].worker_routing_key_load().value(), 1);
        assert_eq!(workers[2].worker_routing_key_load().value(), 0);

        let headers = headers_with_routing_key("new-key");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };
        let (result, _) = policy.select_worker_impl(&workers, &info);
        let selected_idx = result.unwrap();

        assert_eq!(selected_idx, 2, "Should select worker with 0 routing keys");
    }

    #[test]
    fn test_min_load_select_prefers_worker_with_fewer_requests() {
        let config = ManualConfig {
            assignment_mode: ManualAssignmentMode::MinLoad,
            ..Default::default()
        };
        let policy = ManualPolicy::with_config(config);
        let workers = create_workers(&["http://w1:8000", "http://w2:8000", "http://w3:8000"]);

        workers[0].increment_load();
        workers[0].increment_load();
        workers[1].increment_load();

        assert_eq!(workers[0].load(), 2);
        assert_eq!(workers[1].load(), 1);
        assert_eq!(workers[2].load(), 0);

        let headers = headers_with_routing_key("new-key");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };
        let (result, _) = policy.select_worker_impl(&workers, &info);
        let selected_idx = result.unwrap();

        assert_eq!(selected_idx, 2, "Should select worker with 0 load");
    }

    #[test]
    fn test_min_group_sticky_after_assignment() {
        let config = ManualConfig {
            assignment_mode: ManualAssignmentMode::MinGroup,
            ..Default::default()
        };
        let policy = ManualPolicy::with_config(config);
        let workers = create_workers(&["http://w1:8000", "http://w2:8000"]);

        workers[0].worker_routing_key_load().increment("key-0");
        workers[1].worker_routing_key_load().increment("key-1");
        workers[1].worker_routing_key_load().increment("key-2");

        let headers = headers_with_routing_key("new-key");
        let info = SelectWorkerInfo {
            headers: Some(&headers),
            ..Default::default()
        };

        let (first_result, branch) = policy.select_worker_impl(&workers, &info);
        let first_idx = first_result.unwrap();
        assert_eq!(branch, ExecutionBranch::Vacant);
        assert_eq!(
            first_idx, 0,
            "Should select worker 0 (has 1 routing key vs 2)"
        );

        for _ in 0..10 {
            let (result, branch) = policy.select_worker_impl(&workers, &info);
            assert_eq!(
                result,
                Some(first_idx),
                "Same routing key should route to same worker"
            );
            assert_eq!(branch, ExecutionBranch::OccupiedHit);
        }
    }

    #[test]
    fn test_random_mode_does_not_consider_load() {
        let config = ManualConfig {
            assignment_mode: ManualAssignmentMode::Random,
            ..Default::default()
        };
        let policy = ManualPolicy::with_config(config);
        let workers = create_workers(&["http://w1:8000", "http://w2:8000"]);

        workers[0].worker_routing_key_load().increment("key-1");
        workers[0].worker_routing_key_load().increment("key-2");
        workers[0].worker_routing_key_load().increment("key-3");

        let mut selected_worker_0 = false;
        for i in 0..50 {
            let headers = headers_with_routing_key(&format!("test-{}", i));
            let info = SelectWorkerInfo {
                headers: Some(&headers),
                ..Default::default()
            };
            let (result, _) = policy.select_worker_impl(&workers, &info);
            if result == Some(0) {
                selected_worker_0 = true;
                break;
            }
        }
        assert!(
            selected_worker_0,
            "Random mode should sometimes select worker 0 despite higher load"
        );
    }

    // 09-16: keyless (NoRoutingId) requests now route to the least-loaded worker
    // instead of random, so even headerless traffic spreads instead of piling up.
    fn assert_no_routing_key_uses_min_load(
        assignment_mode: ManualAssignmentMode,
        setup_load: impl Fn(&[Arc<dyn Worker>]),
    ) {
        let config = ManualConfig {
            assignment_mode,
            ..Default::default()
        };
        let policy = ManualPolicy::with_config(config);
        let workers = create_workers(&["http://w1:8000", "http://w2:8000"]);
        // worker 0 is busy (2 in-flight); worker 1 is idle (0).
        workers[0].increment_load();
        workers[0].increment_load();
        setup_load(&workers);

        for _ in 0..50 {
            let info = SelectWorkerInfo::default();
            let (result, branch) = policy.select_worker_impl(&workers, &info);
            assert_eq!(branch, ExecutionBranch::NoRoutingId);
            assert_eq!(
                result,
                Some(1),
                "keyless request must go to the idle worker (min load), never the busy one"
            );
        }
    }

    #[test]
    fn test_no_routing_key_uses_min_load_in_min_load_mode() {
        assert_no_routing_key_uses_min_load(ManualAssignmentMode::MinLoad, |_| {});
    }

    #[test]
    fn test_no_routing_key_uses_min_load_in_min_group_mode() {
        // In MinGroup mode a key on worker 1 would make min_group avoid it, but
        // min_load (request load) still picks worker 1 (idle) — proves keyless
        // routing is driven by request load, not key count.
        assert_no_routing_key_uses_min_load(ManualAssignmentMode::MinGroup, |workers| {
            workers[1].worker_routing_key_load().increment("k1");
        });
    }
}
