# Spec Review

**Spec:** /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/docs/superpowers/specs/2026-08-01-fileflows-movie-encoding-design.md  
**Reviewer:** GPT-5.6-sol (Codex)  
**Verdict:** Not ready — storage placement and two decision gates are not executable as specified.

## Findings

### F1 — Defect
**Where:** §7.3 Scratch placement and §9 Fail-closed preflight  
**Mechanism:** an `ephemeral-storage` request equal to the scratch budget is said to place the Job only on a node with real headroom; preflight checks free space on “the candidate node,” but the Job has no binding to that node  
**Failure:** Kubernetes schedules from allocatable capacity minus requests, not current free disk. It can place the unpinned Job on a different node whose allocatable budget passes while its actual free NVMe does not, bypassing the preflight’s claimed placement guarantee  
**When:** candidate nodes differ in actual free space, while the lower-free node still has enough unrequested allocatable ephemeral storage for the Job

### F2 — Defect
**Where:** §8.4 x265 reference sweep and §11.3 x265 comparison gate  
**Mechanism:** four x265 points at CRF 18/20/22/24 are used to calculate QSV’s bitrate premium at matched VMAF by interpolation  
**Failure:** interpolation is undefined when the QSV target VMAF lies outside the VMAF range bracketed by those four x265 points, so §11.3 cannot produce a verdict  
**When:** for example, an eligible QSV result scores VMAF 95 while every x265 CRF point scores above 96, or the reverse occurs at the high end

### F3 — Defect
**Where:** §8.6 Plex contention protocol  
**Mechanism:** the baseline consists of three fixed-start playback runs, while only case (d) specifies a seek every two minutes; case (d) passes only if seek-to-resume latency stays within three seconds of baseline  
**Failure:** a literal baseline execution produces no seek-to-resume samples, leaving no baseline value against which case (d) can be evaluated  
**When:** the operator follows the stated baseline protocol without adding an unstated seek sequence

### F4 — Contradiction
**Where:** §3.1 Torrent hardlink economics and §8.1 Census  
**§3.1 says:** there are four lifecycle states, with `already cleaned / never torrented` combined under the same `st_nlink == 1` observation  
**§8.1 says:** the census yields one of five states, separating `never-torrented` from `already-cleaned`  
**Why both cannot hold:** after public cleanup removes the download-side name, both an already-cleaned file and a never-torrented file present as an unlinked library file; the specified census inputs contain no durable history that can split the combined §3.1 state into the two §8.1 outputs

### F5 — Ambiguity
**Where:** §8.5 Run scoping and resume  
**Reading 1:** `encode-benchmark-run` accepts an existing run-id, preserves its original timestamp, and resumes that exact directory  
**Reading 2:** each invocation computes the manifest identity hash, searches timestamped directories for a matching suffix, and resumes a matching prior run automatically  
**Implementation difference:** the first adds a run-id parameter and explicit operator selection; the second adds directory discovery and collision/latest-run rules. Without either mechanism, every fresh UTC timestamp creates a new run and the promised resume never occurs

### F6 — Ambiguity
**Where:** §11.1 Per-variant quality gate  
**Reading 1:** pool every frame from every clip in the cohort, then calculate one harmonic mean and one 1% low for the pooled distribution  
**Reading 2:** calculate both metrics independently per clip and require every clip to meet both thresholds  
**Implementation difference:** the first permits strong clips to offset a weak clip; the second rejects the setting on any weak clip, producing different eligible settings and cohort winners

### F7 — Ambiguity
**Where:** §6 Copy-back spike, §8.5 run directory, §8.7 Plex review, and §13 Deliverables  
**Reading 1:** persist every encoded clip and full-title output beneath an undeclared `encodes/` directory in each run, then expose finalists to the temporary Plex library  
**Reading 2:** persist only selected finalists and delete intermediate or savings-panel outputs after measurement, requiring an additional selection-and-copy stage  
**Implementation difference:** the implementations write materially different artifacts and quantities to SMB, require different workflow stages, and give `encode-benchmark-clean` different deletion scope; the declared run tree and deliverables specify neither

### F8 — Scope
**Type:** Unrequested  
**Where:** §8.7 Temp Plex library and §9.1 Reversibility  
**Brief says:** “No change to Plex … as part of this work.”  
**Mismatch:** creating and later removing a temporary Plex library mutates Plex’s persisted configuration and, by §9.1’s own account, leaves thumbnail or metadata residue in its config PVC

## Grounding

- **Spec identity:** Checked the file with SHA-256. Found `b73417461223ea14…`, matching the request.

- **Media storage and hardlinks:** Checked [persistentvolume.yaml](/Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/kubernetes/apps/media/storage/app/persistentvolume.yaml:1), [Radarr values](/Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/kubernetes/apps/media/radarr/app/values.yaml:1), [qbit_manage config](/Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/kubernetes/apps/media/qbit-manage/app/config.yml:1), and [qbit-manage.md](/Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/docs/qbit-manage.md:100). Found one SMB share, Radarr’s shared `/data` mount, server-inode-preserving mount configuration, and documented real hardlink examples. Live link counts for the catalog are **UNVERIFIED**.

- **Lifecycle classification:** Checked qbit_manage’s configuration and deployment. Found current torrent tags and policy are available through qBittorrent, with credentials in an existing SOPS Secret, but found no durable repository-backed history that identifies torrents already removed by cleanup. This supports F4.

- **GPU topology:** Checked [intel-gpu-plugin daemonset.yaml](/Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/kubernetes/apps/kube-system/intel-gpu-plugin/app/daemonset.yaml:1), [Plex values](/Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/kubernetes/apps/media/plex/app/values.yaml:1), and [nuc-cluster.md](/Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/docs/nuc-cluster.md:1). Found three NUCs, no `shared-dev-num` argument, Plex requesting one `gpu.intel.com/i915`, and no Plex PriorityClass. Intel documents the omitted flag’s default as 1 and describes that mode as one container per GPU. [Intel GPU plugin documentation](https://intel.github.io/intel-device-plugins-for-kubernetes/cmd/gpu_plugin/README.html). Live allocatable GPU counts and Plex’s current placement are **UNVERIFIED**.

- **Ephemeral-storage placement:** Checked Kubernetes scheduling semantics. Requests constrain the sum of scheduled requests against node allocatable storage; they do not attest current free bytes. [Kubernetes resource-management documentation](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/). No benchmark Job or node-binding mechanism currently exists in the repository, supporting F1.

- **Plex persistence:** Checked [Plex values](/Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/kubernetes/apps/media/plex/app/values.yaml:90). Found Plex’s library/configuration is retained on its config PVC and Plex already mounts the SMB share root. A library added through the UI therefore changes persisted Plex state, supporting F8.

- **Guarded recipes:** Checked [rollout.sh](/Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/scripts/lib/rollout.sh:1) and existing bootstrap recipes. Found `require_deployed_source` verifies a clean checkout and rollout-specific paths against the current remote `origin/main`, matching the stated convention. The proposed benchmark recipe names, guard values, and guarded path sets do not yet exist and are **UNVERIFIED**.

- **Notifications:** Checked [ntfy server.yml](/Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/kubernetes/apps/monitoring/ntfy/app/server.yml:1) and [kube-prometheus-stack values](/Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml:44). Found deny-by-default/login-required ntfy configuration and the Alertmanager-to-ntfy receiver. Generation of benchmark completion notifications is **UNVERIFIED** because no benchmark alert source exists yet.

- **Runtime image:** No image is pinned in the repository. LinuxServer’s current documentation lists QSV/oneVPL, libvmaf, and x265 support, but digest selection, arbitrary UID 568 behavior, the required VMAF model, and a real cluster QSV encode remain **UNVERIFIED**, as the spec records. [LinuxServer ffmpeg documentation](https://docs.linuxserver.io/images/docker-ffmpeg/).

- **Source-plan boundary:** Searched tracked `plans/` and spec paths. Found no tracked `fileflows-movie-evaluation-implementation-plan.md`; only this design and its review request are present.
