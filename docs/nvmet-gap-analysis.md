# ioutgt vs kernel nvmet — feature gap analysis

Snapshot: ioutgt worktree `ioutgt-buffer` @ `dc42918` (2026-08-26) vs
Linux `~/git/linux-ioutgt` `drivers/nvme/target/` @ v7.2-2578-gfb90f0f6bfe9.
Method: two independent feature inventories (Appendix A: nvmet, Appendix B:
ioutgt), each item in §1 re-verified by hand against both trees.
Companion to `docs/nvmet-comparison.md` (design comparison); this file is
about *what is missing*, ranked by importance.

Path shorthand: N = `crates/ioutgt-nvme/src`, T = `crates/ioutgt-nvme-tcp/src`,
R = `crates/ioutgt-nvme-rdma/src`, K = `drivers/nvme/target`.

---

## 1. Top 8 gaps, in importance order

### 1. VWC not advertised → host never sends Flush/FUA (durability bug)

- **nvmet:** `id->vwc = NVME_CTRL_VWC_PRESENT` unconditionally
  (`K/admin-cmd.c:735`); Get Features `VOLATILE_WC` returns 1; the bdev
  backend's flush then no-ops when `!bdev_write_cache`.
- **ioutgt:** `IdentifyController.vwc` exists (`N/identify.rs:62`) but
  `N/admin.rs` never sets it → 0.
- **Effect:** the Linux host does
  `lim.features &= ~(BLK_FEAT_WRITE_CACHE | BLK_FEAT_FUA)`
  (`drivers/nvme/host/core.c:2454-2457`) and never issues Flush or FUA
  writes. `FileBackend::flush` (`file.rs:380`, fsync) and the FUA-after-write
  path (`N/io.rs:178`) are dead code in real interop. On a disk with a
  volatile write cache, a host `fsync()` returns with data not durable at
  the target.
- **Fixed (2026-08-26):** Identify Controller sets `vwc::PRESENT` and Get
  Features `VOLATILE_WC` reports 1 on IO controllers, as nvmet does; the
  backend decides whether Flush is a no-op. Gates: `tests/write_cache.rs`;
  the guest fio stage now asserts the host queue is `write back`/`fua=1`
  and runs fsync + FUA passes (target counters showed Flush on the wire
  for the first time: `flush 254` on one IO queue).

### 2. No in-band authentication, no TLS

- **nvmet:** DH-HMAC-CHAP (`K/auth.c`, `K/fabrics-cmd-auth.c`,
  `nvme_fabrics_type_auth_send/receive`, allowed on admin and IO queues),
  per-host `dhchap_key / dhchap_ctrl_key / dhchap_hash / dhchap_dhgroup`
  configfs attrs, `NVME_SC_AUTH_REQUIRED` gate, secure concatenation
  (auth-derived TLS PSK). TLS 1.3 PSK via kernel keyring
  (`K/tcp.c:nvmet_tcp_tls_handshake`, `nvmet_tcp_tls_key_lookup`,
  `addr_tsas=tls1.3`, `addr_treq`, plaintext fallback via
  `nvmet_tcp_try_peek_pdu`).
- **ioutgt:** zero hits for tls/psk/dhchap/auth in any crate; Connect-time
  checks are hostnqn ACL only (enforced since `f4793da`,
  `N/fabrics_exec.rs:319-326`).
- **Why it matters:** any deployment leaving a lab needs at least one.

### 3. No ANA

- **nvmet:** `ana_groups/` (max 128), per-port `ana_state`
  (optimized / non-optimized / inaccessible / persistent-loss / change),
  `NVME_LOG_ANA` with RGO, ANA-change AEN, `nvmet_check_ana_state` on the
  IO path, CMIC = `MULTI_PORT | MULTI_CTRL | ANA`, `anatt=10`.
- **ioutgt:** CMIC ANA bit deliberately clear, `anagrpid = 0`
  (`N/admin.rs:181,262`), no ANA log. `control/nvmet.rs:12` already parses
  and drops `ana_groups` from nvmetcli configs.
- **Effect:** multipath works, but every path is "optimized" forever — no
  failover signalling, no preferred-path control for multi-port/HA.

### 4. Controller error handling and lifecycle

- **nvmet:** `nvmet_ctrl_fatal_error` (`K/core.c:1778`) sets CSTS.CFS and
  `ops->delete_ctrl` kills *all* queues of the controller; 128-slot error
  log filled by `nvmet_set_error` with the CQE "more" bit; queue-depth
  problems are per-command errors; Abort is a no-op returning "not aborted".
- **ioutgt:**
  - KA expiry / admin teardown closes only the admin socket; IO queues
    outlive their controller (roadmap §4, still open — `registry.rs` holds
    no fd/shutdown handle).
  - `CC.SHN` reaches `SHST_COMPLETE` without tearing down IO queues.
  - Queue-depth overrun still terminates the connection.
  - Error log is zero-filled (`N/admin.rs:354`).
  - Abort → `INVALID_OPCODE|DNR` (`N/admin.rs:62`). Minor: nvmet's no-op
    leads to the same host-side reset.
  - RDMA ignores the Connect SQ-flow-control-disable bit
    (`R/target.rs:1541`, always `sqhd_disabled=false`); TCP honours it.
- **Why it matters:** these bite exactly when a host misbehaves.

### 5. Admin surface breadth (Identify / Features / Log pages / RAE / identity)

- **nvmet:** 9 Identify CNS values (00,01,02,03,05,06,07,08,19); 8
  fabrics-usable FIDs (`NUM_QUEUES, KATO, ASYNC_EVENT, HOST_ID,
  VOLATILE_WC, WRITE_PROTECT, RESV_MASK`, + `ARBITRATION/IRQ_*` PCI-only);
  12 LIDs (`SUPPORTED, ERROR, SMART` (real, from part_stat), `FW_SLOT,
  CHANGED_NS, CMD_EFFECTS, ENDURANCE_GROUP, ANA, FEATURES, RMI,
  RESERVATION, DISC`) with RAE honoured via `nvmet_clear_aen_bit`; size
  revalidate → changed-NS AEN; write protect.
- **ioutgt:** CNS 00/01/02/03 (UUID desc only, no NGUID/EUI64); Get FIDs
  `NUM_QUEUES/KATO/AEC`, Set adds no-op `HOST_ID`; LIDs: `CHANGED_NS`
  (RAE ignored, `N/admin.rs:343`), `DISCOVERY`, zero-filled
  `ERROR/SMART/FW_SLOT`; no `CMD_EFFECTS`, LPO only on discovery.
- **Identity:** `MN` hard-coded `"ioutgt"` — the nvmetcli `model` attr is
  parsed but unused (`N/admin.rs:159`); IEEE OUI, VID, SSVID zero;
  nguid/eui64 zero.
- **Why it matters:** `nvme-cli` tooling and monitoring parity more than IO.

### 6. bdev backend fidelity: 512 B hard-coded, no-op discard, no passthru

- **nvmet:** `blksize_shift` from `bdev_logical_block_size()` (cap 4 KiB);
  `nvmet_bdev_set_limits` (nawun/nawupf/npwg/npwa/npdg/npda/nows,
  `dlfeat=WZDS|DRB`); real `__blkdev_issue_discard` /
  `__blkdev_issue_zeroout`; whole-controller passthru (`K/passthru.c`,
  `admin_timeout/io_timeout/clear_ids`); `buffered_io` opt-in.
- **ioutgt:** LBA shift hard-coded 9 for every backend
  (`crates/ioutgt-control/src/server.rs:163`), `nlbaf=0`; `discard`
  returns `Ok(())` for non-regular files (`file.rs:390-392`) while ONCS
  advertises DSM|WRITE_ZEROES (`N/admin.rs:224`) — the host believes thin
  space is reclaimed; no passthru.
- **Effect:** on a 4Kn device the O_DIRECT path gets `EINVAL` on any
  512-aligned-but-not-4K-aligned host IO. Roadmap names
  `IORING_OP_URING_CMD` as the discard fix shape.

### 7. Namespace data features: reservations, ZNS, PI

- **nvmet:** reservations (`K/pr.c`: register/acquire/release/report, all 6
  rtypes, PREEMPT_AND_ABORT via percpu_ref drain, `NVME_LOG_RESERVATION`,
  `RESV_MASK`, per-NS `resv_enable`, no PTPL); ZNS (`K/zns.c`: zone
  append/mgmt send+recv, auto on zoned bdev); PI (T10 DIF, extended-LBA,
  **RDMA-only** — `nvmet_enable_port` rejects PI on TCP).
- **ioutgt:** none of the three (ms=0, mc/dpc/dps 0, `N/admin.rs:247-264`).
- **Why it matters:** reservations for clustered hosts; PI for the RDMA
  binary only; ZNS niche. Correctly demand-driven in the roadmap.

### 8. Live control plane, discovery, observability, sizing knobs

- **nvmet:** live add/remove of ports, subsystems, port↔subsystem links,
  `hosts/`, `referrals/`, root `discovery_nqn`; persistent discovery
  controllers with genctr and `nvmet_port_disc_changed` AEN
  (`K/discovery.c:28`); `disc_traddr` wildcard fixup; debugfs per-ctrl
  state (`port, hostnqn, kato, state, host_traddr, tls_key`, write "fatal");
  tracepoints `nvmet_req_init/complete/async_event`;
  `param_max_queue_size` 16..1024, `attr_qid_max` up to 128 IO queues
  independent of CPU count; `param_mdts`.
- **ioutgt:** startup-frozen port/subsystem graph (restart per port);
  static `genctr: 1` (`N/admin.rs:373`); no DISC_CHANGE AEN; `0.0.0.0`
  advertised verbatim, adrfam hard-coded IPv4; `GET_STATS` counters +
  `LIST_CONTROLLER` + `RUST_LOG` only; MQES 255 (`io_queue_size` ≤ 256);
  `max_qid` = IO-thread count so many-core hosts get fewer queues than CPUs;
  MDTS fixed 128 KiB.

---

## 2. Where ioutgt is ahead of nvmet (not gaps)

- **C2HTermReq / H2CTermReq.** nvmet TCP never sends a C2HTermReq and does
  not parse H2CTermReq — every protocol error is `kernel_sock_shutdown` or
  `nvmet_ctrl_fatal_error`. ioutgt emits typed FES codes
  (`INVALID_PDU_HDR`, `PDU_SEQ_ERR`, `DATA_OUT_OF_RANGE`,
  `DATA_LIMIT_EXCEEDED`, `HDR_DIGEST_ERR`; `T/recv.rs`).
- **DDGST mismatch.** nvmet sets `CMD_SEQ_ERROR` then tears the connection
  down before the CQE is ever sent (`nvmet_tcp_try_recv_ddgst → -EPROTO`).
  ioutgt returns per-command `DATA_XFER_ERROR` and keeps the connection
  (`T/recv.rs:212-218`).
- **Zero-copy send** (`--send-zc`, `SENDMSG_ZC`); nvmet has no ZC send.
- **Adaptive poll** on the RDMA binary (`--poll`).
- **Per-queue stats** without atomics (`GET_STATS`, `ioutgt stat -i`).

## 3. Corrections owed to `docs/nvmet-comparison.md`

- **§2:** "DDGST failure … matching nvmet" — wrong in ioutgt's favour; nvmet
  tears the connection down (see §2 above).
- **§3 (line ~150):** "Host ACLs … not yet enforced beyond a flag check" —
  stale; enforced since `f4793da` (`N/fabrics_exec.rs:319-326`,
  `core/subsystem.rs:135-137`, default deny-unless-listed
  `control/nvmet.rs:190-191`).

## 4. Out of scope (not counted)

FC / fcloop, loop, pci-epf transports; `p2pmem`; PCI-only features
(create/delete SQ/CQ, ARBITRATION, IRQ_COALESCE/IRQ_CONFIG).

---

## Appendix A — kernel nvmet feature inventory

Source: `K/` @ v7.2-2578-gfb90f0f6bfe9. Refs are file:function.

### A.1 Admin commands (`admin-cmd.c:nvmet_parse_admin_cmd`)

Dispatch: fabrics → `nvmet_parse_fabrics_admin_cmd`; discovery subsys →
`discovery.c:nvmet_parse_discovery_cmd`; `nvmet_check_ctrl_status` (CC.EN,
CSTS.RDY, auth); passthru → `passthru.c:nvmet_parse_passthru_admin_cmd`;
then:

- `delete_sq/create_sq/delete_cq/create_cq` → PCI-epf only via `ctrl->ops`
  (fabrics → invalid)
- `get_log_page` → `nvmet_execute_get_log_page`
- `identify` → `nvmet_execute_identify`
- `abort_cmd` → `nvmet_execute_abort`: no-op, result=1 (not aborted), acl=3
- `set_features/get_features` → `nvmet_execute_{set,get}_features`
- `async_event` → `nvmet_execute_async_event`: max `NVMET_ASYNC_EVENTS`=4
  outstanding else `NVME_SC_ASYNC_LIMIT`
- `keep_alive` → `nvmet_execute_keep_alive`: `KA_TIMEOUT_INVALID` if kato==0
- default → `nvmet_report_invalid_opcode`

Not implemented: ns mgmt/attach, fw download/commit, format, security
send/recv, self-test, sanitize, get LBA status, directives, doorbell buf,
virt mgmt, MI. `oacs=0`. Fused commands rejected (`core.c:nvmet_req_init`,
INVALID_FIELD). PSDT must be SGL_METABUF for fabrics.

**Identify CNS** (`nvmet_execute_identify`):

- 00h NS → `nvmet_execute_identify_ns`: zeroed buf if not found;
  `nvmet_ns_revalidate` + `nvmet_ns_changed` on size change; nsze=ncap,
  nuse=0 if ANA inaccessible/persistent-loss; nmic=SHARED; anagrpid; rescap
  if pr.enable (all 6 rtypes + IEKEY_VER_1_3_DEF); endgid=nsid; nguid;
  single LBAF (nlbaf=0, ds=blksize_shift); PI fields (dpc all types,
  mc=EXTENDED_LBA, dps=pi_type, flbas=META_EXT, lbaf[0].ms) iff
  `ctrl->pi_support && nvmet_ns_has_pi`; nsattr RO; bdev limits via
  `io-cmd-bdev.c:nvmet_bdev_set_limits` (nsfeat bit1 + OPTPERF,
  nawun/nawupf/nacwu, npwg/npwa/npdg/npda/nows, dlfeat=WZDS|DRB if
  write_zeroes_unmap)
- 01h CTRL → `nvmet_execute_identify_ctrl` (A.5)
- 02h NS_ACTIVE_LIST → `nvmet_execute_identify_nslist(false)`; rejects nsid
  0xFFFFFFFE/0xFFFFFFFF
- 03h NS_DESC_LIST → `nvmet_execute_identify_desclist`: UUID (if nonzero),
  NGUID (if nonzero), CSI. No EUI64.
- 05h CS_NS: NVM → `nvme_execute_identify_ns_nvm` (npdgl/npdal); ZNS →
  `zns.c:nvmet_execute_identify_ns_zns` (zsze, mor, mar)
- 06h CS_CTRL: NVM → `nvmet_execute_identify_ctrl_nvm` (all zero); ZNS →
  `zns.c:nvmet_execute_identify_ctrl_zns` (zasl=min(mdts, subsys->zasl))
- 07h NS_ACTIVE_LIST_CS → `nvmet_execute_identify_nslist(true)`
- 08h NS_CS_INDEP → `nvmet_execute_id_cs_indep`: nstat=NRDY, anagrpid, nmic
  SHARED, RO, NS_ROTATIONAL if bdev_rot, VWC_NOT_PRESENT if
  !bdev_write_cache
- 19h ENDGRP_LIST → `nvmet_execute_identify_endgrp_list` (endgid==nsid)
- Discovery ctrl: only CNS_CTRL (`discovery.c:nvmet_execute_disc_identify`)

**Set Features** (`nvmet_execute_set_features`): ARBITRATION (PCI only),
NUM_QUEUES (result=(max_qid-1)|(max_qid-1)<<16; rejects 0xffff),
IRQ_COALESCE/IRQ_CONFIG (PCI only), KATO (`nvmet_set_feat_kato`: restart
timer, seconds granularity), ASYNC_EVENT (`nvmet_set_feat_async_event`,
mask `NVMET_AEN_CFG_ALL` = 5 SMART bits + NS_ATTR + ANA_CHANGE), HOST_ID
(`nvmet_set_feat_host_id`: PCI only, 128-bit only; fabrics →
CMD_SEQ_ERROR), WRITE_PROTECT (`nvmet_set_feat_write_protect`:
ns->readonly + flush + `nvmet_ns_changed`), RESV_MASK
(`pr.c:nvmet_set_feat_resv_notif_mask`). Default INVALID_FIELD|DNR.

**Get Features** (`nvmet_execute_get_features`):
ARBITRATION/IRQ_COALESCE/IRQ_CONFIG (PCI), ASYNC_EVENT (aen_enabled),
VOLATILE_WC (=1 hardcoded), NUM_QUEUES, KATO (kato*1000 ms), HOST_ID
(cdw11 bit0=128-bit; copies ctrl->hostid — the only data-carrying get,
`nvmet_feat_data_len`), WRITE_PROTECT, RESV_MASK.
POWER_MGMT/TEMP_THRESH/ERR_RECOVERY/WRITE_ATOMIC are `#if 0`.
Discovery ctrl: KATO, ASYNC_EVENT (mask DISC_CHANGE only)
(`discovery.c:nvmet_execute_disc_{set,get}_features`).
Supported-features log (`nvmet_execute_get_log_page_features`):
NUM_QUEUES/KATO/ASYNC_EVENT/HOST_ID (CSCPE), WRITE_PROTECT/RESV_MASK
(NSCPE).

**Get Log Page** (`nvmet_execute_get_log_page`; transfer len must equal
`nvmet_get_log_page_len(NUMDU/NUMDL)`; LPO only honoured by discovery log):

- 00h SUPPORTED → lists 00,01,02,03,04,05,09,0C,12,16,80
- 01h ERROR → ring of `NVMET_ERROR_LOG_SLOTS`=128 filled by
  `core.c:nvmet_set_error` (sqid/cmdid/status/param_error_location/lba/
  nsid; sets CQE "more" bit 14)
- 02h SMART → per-nsid or NSID_ALL from part_stat
  (`nvmet_get_smart_log_{nsid,all}`); num_err_log_entries; rest zero
- 03h FW_SLOT → zeros
- 04h CHANGED_NS → changed_ns_list, 0xffffffff overflow marker; clears;
  RAE-clears `NVME_AEN_BIT_NS_ATTR`
- 05h CMD_EFFECTS → by CSI: admin CSUPP get_log/identify/abort/
  set+get_features/AER/KA (+SQ/CQ for PCI); IO: read/flush/dsm/resv_*
  CSUPP; write/write_zeroes CSUPP|LBCC; ZNS: zone_append/zone_mgmt_send
  CSUPP|LBCC, zone_mgmt_recv CSUPP
- 09h ENDURANCE_GROUP → LSI=endgid=nsid, part_stat
- 0Ch ANA → honours LSP RGO; chgcnt=`nvmet_ana_chgcnt`; RAE-clears
  `AEN_BIT_ANA_CHANGE`
- 12h FEATURES → supported-features log
- 16h RMI → INVALID_FIELD unless bdev_rot
- 80h RESERVATION → `pr.c:nvmet_execute_get_log_page_resv` (kfifo
  `NVMET_PR_LOG_QUEUE_SIZE`=64 per ctrl, lost-count accounting)
- 70h DISC → `discovery.c:nvmet_execute_disc_get_log_page` (disc ctrl only;
  LPO honoured, dword-aligned, bounds-checked; RAE-clears
  `AEN_BIT_DISC_CHANGE`)

RAE: `nvmet.h:nvmet_clear_aen_bit` — cdw10 bit15 clear → `clear_bit(bn,
ctrl->aen_masked)`. `nvmet_aen_bit_disabled = !(aen_enabled & bit) ||
test_and_set_bit(aen_masked)`. One AEN per type until host reads the log
without RAE.

### A.2 Fabrics + auth

`fabrics-cmd.c`: property_set → `nvmet_execute_prop_set`: only
`NVME_REG_CC` (→ `core.c:nvmet_update_cc`), attrib must be 0. property_get
→ `nvmet_execute_prop_get`: 8B CAP; 4B VS, CC, CSTS, CRTO.
auth_send/auth_receive → `fabrics-cmd-auth.c:nvmet_execute_auth_{send,
receive}` (CONFIG_NVME_TARGET_AUTH; admin and IO queues). connect →
`nvmet_parse_connect_cmd` → `nvmet_execute_{admin,io}_connect`; only
command valid on an unconnected queue (`core.c:nvmet_req_init`).

Connect: recfmt==0 (CONNECT_FORMAT); admin cntlid must be 0xffff (dynamic
only); `nvmet_install_queue`: sqsize!=0, qid not already created
(CMD_SEQ_ERROR), IO sqsize<=MQES (CONNECT_INVALID_PARAM+IATTR), cmpxchg
sq->ctrl (CONNECT_CTRL_BUSY), `cattr & NVME_CONNECT_DISABLE_SQFLOW` →
`sq->sqhd_disabled`, cqe->sq_head=0xffff; `ops->install_queue` hook. IO
connect: `core.c:nvmet_ctrl_find_get` by cntlid+hostnqn;
qid<=subsys->max_qid. Result = cntlid | `NVME_CONNECT_AUTHREQ_ATR` if auth
needed (`nvmet_connect_result`; IO queues never auth).
`core.c:nvmet_host_allowed` (allow_any_host / hosts list; discovery always
allowed). cntlid via `ida_alloc_range(cntlid_min, cntlid_max)`; exhaustion
→ CONNECT_CTRL_BUSY.

CC (`core.c:nvmet_update_cc/nvmet_start_ctrl`): EN 0→1 checks IOSQES=6 /
IOCQES=4 (IO ctrl), MPS=0, AMS=0, CSS in {NVM,CSI} else CSTS.CFS; sets
RDY, re-arms KA; SHN → clear + SHST_CMPLT. CAP (`nvmet_init_cap`): bit37 NVM
CSS, bit43 multi-CSS, TO=15 (7.5 s),
MQES=min(ops->get_max_queue_size, port->max_queue_size)-1.

DH-HMAC-CHAP (`fabrics-cmd-auth.c`, `auth.c`): per-SQ `sq->dhchap_step`
(NEGOTIATE→CHALLENGE→REPLY→SUCCESS1→SUCCESS2 / FAILURE1/2), dhchap_tid,
c1/c2, s1/s2, skey; expiry `nvmet_auth_expired_work`; `nvmet_auth_sq_init`.
`nvmet_auth_negotiate`: napd==1, authid DHCHAP, hash pick (prefer
ctrl->shash_id, fallback first usable), DH group pick (fallback via
crypto_has_kpp); sc_c secure concatenation (SECP_NEWTLSPSK /
REPLACETLSPSK, admin queue only, needs CONFIG_NVME_TARGET_TCP_TLS, NULL DH
rejected) → ctrl->concat. `nvmet_auth_challenge`: random c1,
`nvme_auth_get_seqnum`, DH exponential (`auth.c:nvmet_auth_ctrl_exponential`).
`nvmet_auth_reply`: verify host response (`auth.c:nvmet_auth_host_hash`,
augmented challenge), bidirectional (cvalid → c2, `nvmet_auth_ctrl_hash`),
session key `nvmet_auth_ctrl_sesskey`. SUCCESS2 (or s2==0) + concat:
`auth.c:nvmet_auth_insert_psk` → `nvme_auth_generate_psk` →
`derive_tls_psk` → `nvme_tls_psk_refresh` into ctrl->tls_key.
`auth.c:nvmet_setup_auth` (ctrl alloc + negotiate restart): lookup
`nvmet_host` by hostnqn; skip if allow_any_host, discovery, or queue
already TLS; keys from "DHHC-1:x:" (dhchap_key, dhchap_ctrl_key). Gate
`nvmet_check_auth_status` in `nvmet_check_ctrl_status` +
`nvmet_parse_io_cmd` → `NVME_SC_AUTH_REQUIRED`. Configfs `hosts/<nqn>/`:
dhchap_key, dhchap_ctrl_key, dhchap_hash, dhchap_dhgroup.

TLS (`tcp.c`, CONFIG_NVME_TARGET_TCP_TLS): port `addr_tsas=tls1.3` (needs
port->keyring; `configfs.c:nvmet_addr_tsas_store`); `addr_treq`
required / not required / not specified (TLS defaults required; "not
specified" rejected under TLS; "not required" allows plaintext fallback via
`nvmet_tcp_try_peek_pdu` — if first bytes are ICReq, continue in the clear).
Queue state `NVMET_TCP_Q_TLS_HANDSHAKE` → `nvmet_tcp_tls_handshake`
(`tls_server_hello_psk`, keyring=port->nport->keyring, module param
`tls_handshake_timeout`=10 s) → `nvmet_tcp_tls_handshake_done` →
`nvmet_tcp_tls_key_lookup` (`nvme_tls_key_lookup(peerid)` → sq->tls_key);
queue->tls_pskid. Every `kernel_recvmsg` passes cmsg +
`nvmet_tcp_tls_record_ok` (DATA ok, ALERT fatal/warn, else error).
`nvmet_queue_tls_keyid(sq)` suppresses DH-CHAP (`nvmet_has_auth`). debugfs
tls_key, tls_concat.

### A.3 IO commands

`core.c:nvmet_parse_io_cmd`: fabrics → auth → `nvmet_check_ctrl_status` →
passthru → `nvmet_req_find_ns` → ANA (`nvmet_check_ana_state`:
INACCESSIBLE / PERSISTENT_LOSS / CHANGE → ANA_* status) → write-protect
(`nvmet_io_cmd_check_access`: only read/flush on RO → NS_WRITE_PROTECTED)
→ `pr.c:nvmet_parse_pr_cmd` → by ns->csi: NVM file/bdev parse; ZNS
`zns.c:nvmet_bdev_zns_parse_io_cmd` → `nvmet_pr_check_cmd_access` +
`nvmet_pr_get_ns_pc_ref` if PR.

bdev (`io-cmd-bdev.c:nvmet_bdev_parse_io_cmd`): read, write
(`nvmet_bdev_execute_rw`: REQ_SYNC|REQ_IDLE, FUA→REQ_FUA, inline
bvec<=`NVMET_MAX_INLINE_BIOVEC`=8, bio chaining, PI via
`nvmet_bdev_alloc_bip`), flush (`nvmet_bdev_execute_flush`: no-op if
!bdev_write_cache else REQ_PREFLUSH), dsm (`nvmet_bdev_execute_dsm`: only
NVME_DSMGMT_AD → `__blkdev_issue_discard`; IDR/IDW succeed silently),
write_zeroes (`__blkdev_issue_zeroout`). `blk_to_nvme_status`:
NOSPC→CAP_EXCEEDED, TARGET→LBA_RANGE, NOTSUPP→INVALID_OPCODE,
MEDIUM→ACCESS_DENIED, else INTERNAL; sets error_slba.

file (`io-cmd-file.c:nvmet_file_parse_io_cmd`): read/write
(`nvmet_file_execute_rw`: O_DIRECT unless buffered_io; IOCB_NOWAIT then
workqueue fallback; FUA→IOCB_DSYNC; mempool `NVMET_MAX_MPOOL_BVEC`=16),
flush (vfs_fsync in work), dsm (vfs_fallocate PUNCH_HOLE|KEEP_SIZE for AD),
write_zeroes (ZERO_RANGE|KEEP_SIZE).

Not implemented: compare, verify, copy, write uncorrectable, fused, IO mgmt
send/recv.

ONCS (`nvmet_execute_identify_ctrl`): DSM | WRITE_ZEROES | RESERVATIONS.
vwc=PRESENT always; awun=awupf=0; nwpc bit0; sgls=BYTE_ALIGNED (+KSDBDS if
NVMF_KEYED_SGLS, +SAOS if inline data); mdts via `nvmet.h:nvmet_ctrl_mdts`
(port param_mdts / transport get_mdts); ioccsz=(64+inline_data_size)/16
(inline disabled when PI); iorcsz=1; msdbd=ops->msdbd.

ZNS (`zns.c`, CONFIG_BLK_DEV_ZONED): auto when `bdev_is_zoned`
(`nvmet_bdev_zns_enable`: rejects conventional zones / unaligned capacity;
subsys-wide zasl=min). zone_append (`nvmet_bdev_execute_zone_append`, <=
bdev_max_zone_append_sectors), zone_mgmt_recv (ZRA=ZONE_REPORT only, all
ZRASF filters, partial bit), zone_mgmt_send (OPEN/CLOSE/FINISH/RESET;
select-all RESET native, others emulated per-zone
`nvmet_bdev_zone_mgmt_emulate_all`). No ZRWA / descriptor ext / offline.

Reservations (`pr.c`, per-NS resv_enable): resv_register
(REG/UNREG/REPLACE, iekey), resv_acquire (ACQUIRE/PREEMPT/
PREEMPT_AND_ABORT — abort via per-ctrl percpu_ref drain
`nvmet_pr_do_abort`), resv_release (RELEASE/CLEAR), resv_report (EDS only;
ptpls=0; cntlid=DYNAMIC). All 6 rtypes. `nvmet_pr_check_cmd_access` per
read/write groups. No PTPL. Notify: NVME_AER_CSS /
RESV_LOG_PAGE_AVALIABLE + resv log, masked by RESV_MASK (notify_mask).
Registrants keyed by ctrl hostid from Connect.

### A.4 Namespace-level (`configfs.c:nvmet_ns_attrs`; `core.c:nvmet_ns_enable`)

Attrs: device_path (bdev first, -ENOTBLK → file), enable, buffered_io
(forces file backend even for bdev), device_uuid / device_nguid (-EBUSY
while enabled; uuid auto-gen in `nvmet_ns_alloc`; no eui64), ana_grpid
(live; `nvmet_send_ana_event`), revalidate_size (WO; `nvmet_ns_revalidate`
→ changed-NS AEN), resv_enable (pre-enable only), p2pmem
(CONFIG_PCI_P2PDMA).

PI: auto from bdev integrity (`io-cmd-bdev.c:nvmet_bdev_ns_enable_integrity`:
metadata_size, pi_type TYPE1/TYPE3 only when
metadata_size==sizeof(t10_pi_tuple)); effective iff port param_pi_enable
&& subsys attr_pi_enable (ctrl->pi_support) AND transport
NVMF_METADATA_SUPPORTED (RDMA only; `core.c:nvmet_enable_port` rejects
otherwise). Extended-LBA only.

blksize_shift from `bdev_logical_block_size` / file i_blkbits (cap 4k).
Single LBAF. Size revalidate on Identify NS / Identify NS ZNS / configfs
revalidate_size (no polling). Changed-NS AEN on enable / disable /
write-protect / ana_grpid (`core.c:nvmet_ns_changed`). ANA:
`NVMET_MAX_ANAGRPS`=128, state per PORT (port->ana_state[], configfs
`ports/<n>/ana_groups/<g>/ana_state` in optimized / non-optimized /
inaccessible / persistent-loss / change; grp1 default OPTIMIZED, others
INACCESSIBLE; store bumps `nvmet_ana_chgcnt` + ANA AEN). anacap all 5
states, anatt=10. Write protect via feature (not persistent).

Passthru (`passthru.c`): whole-ctrl, configfs
`subsystems/<nqn>/passthru/{device_path,enable,admin_timeout,io_timeout,
clear_ids}`; exclusive with regular ns; admin allow-list
`nvmet_parse_passthru_admin_cmd` (vendor-specific passed; AER / KA /
NUM_QUEUES / KATO / ASYNC_EVENT / HOST_ID emulated; feature allow-list
`nvmet_passthru_get_set_features`; identify CTRL/NS/DESC_LIST/CS_* with
overrides `nvmet_passthru_override_id_*`; get_log passthrough); IO: all
except reservations (`nvmet_parse_passthru_io_cmd`); subsys->ver inherited
(min 1.2.1); loop ports default clear_ids=1. `NVMET_MAX_NAMESPACES`=1024
(nn, mnan, endgidmax).

### A.5 Controller-level

AENs (`core.c:nvmet_add_async_event`): NOTICE/NS_CHANGED/LOG_CHANGED_NS
(`nvmet_ns_changed`); NOTICE/ANA/LOG_ANA (`nvmet_send_ana_event`,
`nvmet_port_send_ana_event`); NOTICE/DISC_CHANGED/LOG_DISC
(`discovery.c:__nvmet_disc_changed`, disc ctrls);
AER_CSS/RESV_LOG_PAGE_AVALIABLE/LOG_RESERVATION (`pr.c`).
oaes=`NVMET_AEN_CFG_OPTIONAL` (NS_ATTR|ANA_CHANGE); default aen_enabled
same. SMART AENs accepted but never sent. aerl=3. AERs failed INTERNAL on
admin SQ teardown (`nvmet_sq_destroy` → `nvmet_async_events_failall`).

KATO/TBKAS: ctrl->kato seconds (round up); ctratt TBKAS; reset_tbkas on
every `nvmet_req_init` and sq destroy; `nvmet_keep_alive_timer` reschedules
if traffic else `nvmet_ctrl_fatal_error`; disc default
`NVMET_DISC_KATO_MS`=120000 when kato=0; kas=10; timer starts at alloc,
re-armed at CC.EN.

Fatal: `core.c:nvmet_ctrl_fatal_error` sets CSTS.CFS, work →
`ops->delete_ctrl`.

Identify Ctrl (`nvmet_execute_identify_ctrl`): vid/ssvid (attr_vendor_id /
attr_subsys_vendor_id), sn (random per subsys, attr_serial), mn ("Linux",
attr_model), fr (UTS_RELEASE, attr_firmware), ieee (attr_ieee_oui), rab=6,
cntrltype IO/DISC, cmic=MULTI_PORT|MULTI_CTRL|ANA, ver (attr_version,
default 2.1.0), ctratt=HID_128_BIT|TBKAS (+RHII PCI), frmw=1 RO slot, lpa
bits 0,1,2, elpe=127, npss=0, sqes/cqes 6/4, maxcmd=MQES+1, psd[0] fake,
subsys_discovered set on first identify.

cntlid: attr_cntlid_min/max (default NVME_CNTLID_MIN..MAX). Queues:
subsys->max_qid default `NVMET_NR_QUEUES`=128 (attr_qid_max store live →
deletes all ctrls); port param_max_queue_size clamped
`NVMET_MIN/MAX_QUEUE_SIZE` 16..1024; RDMA get_max_queue_size clamps further
(128 with PI). NUM_QUEUES feature returns max_qid-1 regardless of request.
Inline: param_inline_data_size (TCP default 4*PAGE_SIZE; RDMA default
PAGE_SIZE, max 16K); disabled in ioccsz when PI. param_pi_enable (port) +
attr_pi_enable (subsys) → ctrl->pi_support.

SQ flow control: DISABLE_SQFLOW honoured (sqhd_disabled, sq_head=0xffff);
else `core.c:nvmet_update_sq_head` cmpxchg (sqhd+1)%sq->size per
completion. No CQ-full tracking; `nvmet_cq` = ctrl/qid/size/ref only; TCP
allocates nr_cmds=sq->size*2 (`tcp.c:nvmet_tcp_install_queue`), running out
→ -ENOMEM conn error ("should never happen").

hostnqn, hostid (uuid from Connect data), host_traddr via ops->host_traddr
(debugfs). Multi-CSS: CAP bit43; CC.CSS=CSI ok; per-NS csi. Discovery
(`discovery.c`): global `nvmet_disc_subsys`, root attr discovery_nqn
renames it (`configfs.c:nvmet_root_discovery_nqn_store`); both unique and
well-known NQN resolve (`core.c:nvmet_find_get_subsys`); genctr; referrals
(`ports/<n>/referrals/`, `nvmet_referral_enable`); disc_traddr hook fixes
INADDR_ANY; disc ctrl mdts=0, lpa bit2.

### A.6 TCP (`tcp.c`)

Module params: so_priority (`sock_set_priority`), idle_poll_period_usecs
(io_work busy-poll, `nvmet_tcp_check_queue_deadline`),
tls_handshake_timeout. Copies sock rcv_tos to TOS. Consts:
`NVMET_TCP_DEF_INLINE_DATA_SIZE`=4 pages; `NVMET_TCP_MAXH2CDATA`=0x400000
(16 MiB, ICResp maxdata); `NVMET_TCP_BACKLOG`=128 (listen +
pending-teardown cap in install_queue → CONNECT_CTRL_BUSY); RECV_BUDGET=8,
SEND_BUDGET=8, IO_WORK_BUDGET=64 (`nvmet_tcp_io_work`).

ICReq (`nvmet_tcp_handle_icreq`): plen==sizeof, pfv==1.0, hpda==0 else
error; HDGST/DDGST echo host flags; cpda=0. Second ICReq → -EPROTO.

Recv states RECV_PDU → RECV_DATA → RECV_DDGST → RECV_ERR
(`nvmet_tcp_try_recv_one`). Valid inbound PDU types only icreq, cmd,
h2c_data (`nvmet_tcp_pdu_valid`); hlen must match (`nvmet_tcp_pdu_size`);
else -EIO.

**No C2HTermReq ever sent; H2CTermReq not parsed** (no "term" in tcp.c).
All protocol errors → `nvmet_tcp_socket_error` → `kernel_sock_shutdown`
(EPIPE/ECONNRESET/no ctrl) or `nvmet_ctrl_fatal_error` (CFS + delete_ctrl
= all queues of ctrl).

Digests: `nvmet_tcp_verify_hdgst` (mismatch or flag missing → -EPROTO);
`nvmet_tcp_check_ddgst` (flag missing on data PDU → -EPROTO);
`nvmet_tcp_calc_ddgst` crc32c; `nvmet_tcp_try_recv_ddgst`: **DDGST mismatch
→ cqe->status=NVME_SC_CMD_SEQ_ERROR, nvmet_req_uninit, free bufs, -EPROTO
(connection torn down; CQE never actually sent).**

Data-in: inline (sgl.length<=port->inline_data_size && write) consumed
directly; else single R2T for the entire remainder
(`nvmet_setup_r2t_pdu`: r2t_length=transfer_len-rbytes_done, ttag=cmd
index). H2CData checks (`nvmet_tcp_handle_h2c_data_pdu`): ttag<nr_cmds,
data_offset==rbytes_done, data_length==plen-hdr-digests, !=0,
<=MAXH2CDATA, cmd state; else -EPROTO. No maxr2t tracking.

Data-out: `nvmet_setup_c2h_data_pdu` always DATA_LAST; DATA_SUCCESS when
sqhd_disabled (response elided); DDGST appended. Response
`nvmet_setup_response_pdu`. Failed `nvmet_req_init` with inline data:
`nvmet_tcp_handle_req_failure` drains stale bytes
(`NVMET_TCP_F_INIT_FAILED`) before responding. `nvmet_tcp_queue_response`:
llist resp_list → `queue_work_on(queue_cpu)`; defers if inline pending;
`nvmet_tcp_fetch_cmd` picks c2h_data / r2t / rsp.

CPU: `queue_cpu()=sk->sk_incoming_cpu`; `nvmet_tcp_wq`
WQ_MEM_RECLAIM|WQ_HIGHPRI|WQ_PERCPU. Listen sock reuseaddr+nodelay+
so_priority; accepted sock sock_no_linger, data_ready / write_space /
state_change hooked (`nvmet_tcp_set_queue_sock`). Queue depth
nr_cmds=sqsize*2 at Connect; one preallocated connect cmd before; PDUs
page_frag per cmd. States CONNECTING / TLS_HANDSHAKE / LIVE /
DISCONNECTING / FAILED. `nvmet_tcp_ops`: TCP, msdbd=1, no
NVMF_METADATA_SUPPORTED (no PI over TCP), install_queue, disc_traddr,
host_traddr.

### A.7 Observability / management

debugfs (`debugfs.c`, CONFIG_NVME_TARGET_DEBUGFS):
`/sys/kernel/debug/nvmet/<subsysnqn>/ctrl<cntlid>/{port,hostnqn,kato,
state,host_traddr,tls_key,tls_concat}`; state RW, write "fatal" →
`nvmet_ctrl_fatal_error`.

Tracepoints (`trace.h`): `nvmet_req_init` (ctrl_id, disk, qid, cid, opcode,
fctype, flags, nsid, metadata, cdw10[24]), `nvmet_req_complete`
(result, status), `nvmet_async_event`; `trace.c` decoders for identify /
features / rw / dsm / zone / resv / fabrics (connect, prop, auth).

configfs mutability (`configfs.c`): port addr_*/param_* writable only while
port disabled (`nvmet_is_port_enabled` → -EACCES); port enabled on first
subsystem symlink (`nvmet_port_subsys_allow_link` → `nvmet_enable_port`),
disabled on last unlink; add/remove subsys on live port →
`nvmet_port_disc_changed` (disc AEN); allowed_hosts symlinks live
(`nvmet_subsys_disc_changed`), rejected if allow_any_host; ns
add/enable/disable live (changed-NS AEN); ns identity attrs -EBUSY while
enabled; attr_qid_max live (kills ctrls); attr_version "%d.%d.%d";
attr_model <=40 printable; subsys rmdir → `nvmet_subsys_del_ctrls`;
referrals live; ANA groups create/delete/state live; root discovery_nqn.

Limits (`nvmet.h`): NVMET_ASYNC_EVENTS=4, ERROR_LOG_SLOTS=128,
MIN/MAX_QUEUE_SIZE=16/1024, NR_QUEUES=128, MAX_CMD(ctrl)=MQES+1,
MAX_MDTS=255, MAX_NAMESPACES=1024, MAX_ANAGRPS=128, KAS=10,
DISC_KATO_MS=120000, PR_LOG_QUEUE_SIZE=64, MAX_INLINE_BIOVEC=8,
MAX_MPOOL_BVEC=16, DEFAULT_VS=2.1.0, MN/SN/FR max 40/20/8. Transfer-len:
`core.c:nvmet_check_transfer_len` (exact) / `nvmet_check_data_len_lte`;
SGL_INVALID_DATA vs INVALID_FIELD by PSDT.

### A.8 Other transports

`rdma.c` (NVMF_TRTYPE_RDMA): flags KEYED_SGLS|METADATA_SUPPORTED, msdbd=1;
params use_srq, srq_size (>=256, default 1024); inline <=16K / 4 SGEs;
get_mdts (`NVMET_RDMA_MAX_MDTS`=8 → 1 MiB; 5 with PI); get_max_queue_size;
T10-PI via IB_QP_CREATE_INTEGRITY_EN / ib_sig (off if
!IBK_INTEGRITY_HANDOVER); remote invalidate; disc_traddr / host_traddr; CM
events incl. DEVICE_REMOVAL / ADDR_CHANGE; rnr_retry=7.
`fc.c` (nvmet-fc, 3026 lines) + `fcloop.c`: msdbd=1, discovery_chg hook.
`loop.c` (TRTYPE_LOOP=254): in-kernel loopback. `pci-epf.c` (TRTYPE_PCI):
PCI endpoint target; create/delete SQ/CQ, get/set_feature (arbitration,
IRQ coalesce/config), get_mdts; polled SQs / CC.
Kconfig: NVME_TARGET, _DEBUGFS, _PASSTHRU, _LOOP, _RDMA, _FC, _FCLOOP,
_TCP, _TCP_TLS (NET_HANDSHAKE, TLS, NVME_KEYRING, KEYS), _AUTH
(NVME_AUTH), _AUTH_DEBUG, _PCI_EPF.

Notable nvmet gaps relative to ioutgt: no C2HTermReq / H2CTermReq handling
in TCP; no EUI64; no PTPL; no compare / verify / copy; no ns-mgmt /
firmware / format; abort no-op; host-id set PCI-only; PI RDMA-only; single
R2T per cmd; no CQ-full accounting.

---

## Appendix B — ioutgt feature inventory

Source: worktree `ioutgt-buffer` @ `dc42918`.

### B.1 Admin

- Dispatch match `N/admin.rs:37-65`: IDENTIFY 0x06, GET_FEATURES 0x0A,
  SET_FEATURES 0x09, GET_LOG_PAGE 0x02, KEEP_ALIVE 0x18, ASYNC_EVENT 0x0C;
  all else INVALID_OPCODE|DNR (`admin.rs:61-64`). Admin cmd before CC.EN →
  CONNECT_CTRL_BUSY|DNR (`N/dispatch.rs:339-345`).
- Identify CNS (`admin.rs:86-145`): 0x00 NS (inactive NSID<=max_nsid →
  zeroed struct), 0x01 Ctrl, 0x02 Active NS list (<=1024), 0x03 NS desc
  list (UUID NIDT=3 only; no NGUID/EUI64 desc). Others INVALID_FIELD.
- Get Features (`admin.rs:266-278`): NUM_QUEUES 0x07, KATO 0x0F, AEC 0x0B.
  Set Features (`admin.rs:280-303`): NUM_QUEUES (min(req, max_qid-1)),
  KATO, AEC, HOST_ID 0x81 (no-op); else FEATURE_NOT_CHANGEABLE. No
  SEL/save.
- Get Log Page (`admin.rs:315-365`): DISCOVERY 0x70 (discovery ctrl only;
  NUMD+LPO windowed), CHANGED_NS 0x04 (0xFFFFFFFF sentinel, cleared on
  read, RAE ignored `admin.rs:343`), ERROR/SMART/FW_SLOT zero-filled (LPO
  ignored); else INVALID_LOG_PAGE. Discovery genctr hardcoded 1
  (`admin.rs:373`).
- Abort: not found. AER (`admin.rs:43-60`): parks in slot; AERL=3; only
  event = Notice/NS_ATTR_CHANGED DW0 0x00040002 (`dispatch.rs:278-300`),
  gated on AEC bit 8, default AEC=NS_ATTR (`dispatch.rs:182`);
  OAES=NS_ATTR only (`admin.rs:175`). Teardown fails parked AERs
  (`dispatch.rs:238-246`). DISC_CHANGE / firmware / SMART AENs: not found.
- Keep Alive → SUCCESS (`admin.rs:42`). KATO from Connect
  (`N/fabrics_exec.rs:342-359`; discovery default 120 s). Watchdog expiry
  KATO*2+tick (`dispatch.rs:116-131`), tick KATO/2 clamped 250 ms..5 s
  (`dispatch.rs:43-48`); TCP `T/connection.rs:205-211`, RDMA
  `R/target.rs:605`. TBKAS: CTRATT bit 6 set only on TCP IO ctrls
  (`admin.rs:194-196`); RDMA does not publish traffic.
- NS Mgmt/Attach, FW Commit/Download, Self-test, Sanitize, Format NVM: not
  found (OACS=0).

### B.2 Fabrics

- fctype match `N/fabrics_exec.rs:262-278`: CONNECT, PROPERTY_GET,
  PROPERTY_SET; else INVALID_OPCODE. Auth Send/Receive, Disconnect: not
  found.
- Connect (`fabrics_exec.rs:280-411`): recfmt!=0 → CONNECT_FORMAT;
  cntlid!=0xFFFF → INVALID_PARAM (dynamic only); unknown subsys →
  INVALID_PARAM; **host ACL enforced**: `subsys.admits(hostnqn)` →
  CONNECT_INVALID_HOST|DNR (`fabrics_exec.rs:319-326`;
  `core/subsystem.rs:135-137` = allow_any_host || allowed_hosts.contains).
  Config default deny-unless-listed (`control/nvmet.rs:190-191`).
  Duplicate Connect rejected. IO Connect validates
  cntlid/hostnqn/1<=qid<=max_qid/unique (`core/registry.rs:172-198`).
  hostid ignored.
- Property Get (`fabrics_exec.rs:421-438`): CAP, VS=0x00010300, CC, CSTS.
  Property Set: CC only (`:443-465`); NSSR defined (`N/fabrics.rs:205`)
  not handled. CAP=MQES 255|CQR|TO 30 (`N/controller.rs:251-258`). CC.SHN
  → SHST_COMPLETE but IO queues not torn down (roadmap).
- TLS/kTLS/PSK, DH-HMAC-CHAP: not found.
- CATTR bit 2 SQ flow-control disable: TCP honoured (`T/transport.rs:77`,
  `T/lib.rs:40`; sqhd=0 `core/queue.rs:214-217`). RDMA passes
  sqhd_disabled=false always (`R/target.rs:1541`) → ignored.

### B.3 IO

- Match `N/io.rs:65-95`: FLUSH, READ, WRITE, WRITE_ZEROES, DSM; else
  INVALID_OPCODE. Compare / Write Uncorrectable / Verify / Copy / zone /
  reservations: not found.
- ONCS = DSM|WRITE_ZEROES = 0x0C (`admin.rs:224`). FUSES/VWC/FNA/AWUN=0.
- DSM (`io.rs:189-224`): AD only; IDR/IDW no-op.
- FUA (`io.rs:178-182`): write then flush(). Read FUA/LR/PRINFO ignored.
- MDTS 128 KiB check + SGL len must equal NLB*bs (`io.rs:100-118`).
- Metadata/PI: none (ms=0, mc/dpc/dps 0, `admin.rs:247-264`). nlbaf=0,
  single LBAF, block shift hard-coded 9 (512 B) for all backends
  (`control/server.rs:163`).

### B.4 Identity

- ID-NS (`admin.rs:247-264`): nguid/eui64 zero; UUID via CNS 03 from config
  device.uuid or FNV-derived (`subsystem.rs:49-61`; runtime ADD_NAMESPACE
  always derived `server.rs:216`); NMIC=SHARED; dlfeat=1; anagrpid=0.
- ID-CTRL (`admin.rs:148-239`): VID/SSVID 0, IEEE OUI zero, SN=subsys
  serial (default IOUTGT0001, `config.rs:384`) or "ioutgt-disc", MN
  hard-coded "ioutgt" (config `model` attr parsed but not used,
  `admin.rs:159`), FR "1.0", VER 1.3.0, CMIC=MULTI_CTRL bit 1 (ANA bit 3
  clear), CNTRLTYPE 1/2, OAES=NS_ATTR, CTRATT=TBKAS (TCP only), KAS=100,
  SQES 0x66/CQES 0x44, MAXCMD=io_queue_size (default 128, max 256), ACL 3,
  AERL 3, MDTS=5, SGLS byte-aligned (+KEYED|SAOS on RDMA), NN=max_nsid,
  IOCCSZ=(64+16K)/16 TCP / (64+4K)/16 RDMA, IORCSZ 1, ICDOFF 0.
- cntlid 1..=0xFFEF round-robin (`registry.rs:105,130-166`); sliced per port
  process for multi-port (`harness/lib.rs:214-224`).
- Discovery entry (`admin.rs:380-399`): trtype TCP/RDMA, adrfam hard-coded
  IPv4, subtype NVM, TREQ 0, cntlid 0xFFFF, asqsz 32, traddr verbatim
  (0.0.0.0 not fixed up). No self/discovery entry, no referrals.

### B.5 Transport

TCP: ICReq PFV 1.0 only, HPDA!=0 rejected (close), digests = host ∩ policy
(`--no-hdgst`/`--no-ddgst`) `T/handshake.rs:29-73`. MAXR2T stored but
unused (one R2T per cmd always, `T/recv.rs:692-694`). MAXH2CDATA 16 MiB
(`T/lib.rs:71`). C2HTermReq FES generated: INVALID_PDU_HDR (FEI 10/16,
`recv.rs:712-733`), PDU_SEQ_ERR (`recv.rs:626-630`), DATA_OUT_OF_RANGE
(`recv.rs:294,727`), DATA_LIMIT_EXCEEDED (`recv.rs:659,686`),
HDR_DIGEST_ERR (`N/pdu.rs:359`); UNSUPPORTED_PARAM unused. DDGST mismatch
→ per-cmd DATA_XFER_ERROR (`recv.rs:212-218`). H2CTermReq: logged, close,
no reply (`recv.rs:339-341,625`). Depth overrun: Connect sqsize outside
2..=cap rejected at handshake (`T/transport.rs:66-76`; cap=io_queue_size
IO / 256 admin); empty freelist parks recv (`recv.rs:643-653`), no term;
CID conflict detection not found. `--send-zc` SENDMSG_ZC
(`T/main.rs:190-194`), `--recv-buf-mb` provided-buffer ring, qid n → io
thread (n-1)%N (`harness/lib.rs:951`), spread_cpus pinning
(`harness/lib.rs:555,979`). Priority/nice: not found. TLS: not found.

RDMA: CM private data parsed (`R/cmproto.rs`), typed nvme_rdma_cm_rej on
malformed (`R/listener.rs:98-125`), CmRep crqsize=clamped sqsize-1,
initiator_depth=QP max_rd_atomic (`R/target.rs:1516-1571`), admin depth
cap 32 (`target.rs:1456`). Inline 4 KiB in-capsule writes (`N/lib.rs:368`);
bad inline SGL → SGL_INVALID_TYPE / DATA_SGL_LEN_INVALID
(`target.rs:761-767`). Single keyed SGL descriptor only
(`R/sgl.rs:437-445`); 0xF subtype → SEND_WITH_INV (`sgl.rs:412-419`,
`target.rs:946,1446`). WRITE/DSM pulled via RDMA READ; reads pushed RDMA
WRITE+SEND. SRQ: not found. `--poll` adaptive busy-poll
(`R/main.rs:63-68`). Per-queue WR stats (`R/stats.rs`).

### B.6 Backends (`crates/ioutgt-backend`)

AnyBackend = Null | Memory | File (`lib.rs:22-29`). File = regular files +
bdevs (`file.rs:144-231`), O_DIRECT with fallback buffered+RWF_DONTCACHE;
flush=fsync (`file.rs:380`); discard PUNCH_HOLE on files, no-op on bdevs
(`file.rs:388-405`); write-zeroes ZERO_RANGE→PUNCH_HOLE→zero writes
(`file.rs:407-440`). Config-file namespaces always File (`nvmet.rs:174`).
Passthru, zoned, PI, configurable block size, buffered_io knob: not found.

### B.7 Control plane

Config: nvmetcli JSON only (`nvmet.rs:47-97,150-194`): ports[].addr,
ports[].subsystems, subsystems[].attr{serial,model,allow_any_host},
allowed_hosts, namespaces[].device{path,uuid}, enable.
param/ana_groups/referrals/PI/cntlid attrs accepted+ignored
(`nvmet.rs:12-14`). Multi-port = fork per port (`harness/lib.rs:194-262`).
Socket ops (`server.rs:26-55`): ADD_NAMESPACE, REMOVE_NAMESPACE,
LIST_NAMESPACE, GET_STATS{clear}, LIST_CONTROLLER. Runtime
port/subsystem/host-ACL add/remove: not found. CLI ctl/list/stat
(`T/main.rs:254-287`).
Observability: per-queue read/write/flush/other cmds, bytes, errors
(`core/queue.rs:36-58`); per-thread ring stats; RDMA WR stats;
LIST_CONTROLLER (cntlid/hostnqn/kato/queues tid,cpus,peer); tracing via
RUST_LOG (`T/main.rs:290-294`). Prometheus/debugfs: not found. Conn cap 256
(`harness/lib.rs:286`). NS-change AEN on ADD/REMOVE (`server.rs:222,236`).
Discovery log-change AEN, genctr maintenance, referrals: not found.

### B.8 Multipath

CMIC bit 1 + NMIC bit 0 + UUID desc → plain non-ANA multipath
(`admin.rs:176-185,258`; `T/tests/multipath_caps.rs:35-36`). ANA not
present: no ANA log, ANAGRPID 0, CMIC bit 3 clear.

### B.9 Docs' explicit not-done lists

`docs/roadmap.md` §4: gentler depth-overrun; IO-queue teardown on ctrl
removal; dead-thread mailbox leak; RAE semantics, real SMART/error logs,
LPO beyond discovery; persistent discovery ctrl (genctr bump, DISC_CHANGE
AEN, OAES DISC_CHANGE); wildcard-traddr fixup + adrfam; host ACLs in
control API; multiple ports in one process; TLS; bdev discard/write-zeroes
via uring-cmd; NVMe passthrough backend; Metadata/PI, Write Protect,
reservations. §5: graceful shutdown cmd, config reload, Prometheus.
`docs/nvmet-comparison.md:179-185`: minimal log pages, static genctr, no
ANA. `docs/nvme-rdma.md:281-296`: conns pruned only on graceful disconnect;
staged_len not cross-checked vs NLB; over-cap conns dropped without
rdma_reject; bind reports configured addr verbatim.
`docs/architecture.md:490`: RECV_ZC, bundles, IOPOLL ring deferred.
