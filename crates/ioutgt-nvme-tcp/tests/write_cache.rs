//! IO controllers advertise a volatile write cache, both in Identify
//! Controller VWC and through Get Features VOLATILE_WC — see
//! `ioutgt_nvme::identify::vwc` for why the host needs the bit.

mod common;

use common::{Client, NQN};
use ioutgt_nvme::identify::{IdentifyController, vwc};
use ioutgt_nvme::spec;
use ioutgt_nvme::status;
use zerocopy::FromBytes;

fn start_target() -> std::net::SocketAddr {
    let mut config = ioutgt_nvme_tcp::TargetConfig::single_memory(NQN, 16);
    config.listen = "127.0.0.1:0".parse().unwrap();
    config.io_threads = 1;
    ioutgt_nvme_tcp::spawn_target(config).expect("target start")
}

#[test]
fn identify_controller_advertises_volatile_write_cache() {
    let addr = start_target();
    let mut admin = Client::handshake(addr, false, false);
    admin.connect(0, 32, 0xFFFF, 1);
    admin.enable_controller(2);

    let ctrl = admin.identify(spec::cns::CONTROLLER, 0, 3);
    let ctrl = IdentifyController::read_from_bytes(&ctrl).expect("identify controller 4096 bytes");
    assert_eq!(
        ctrl.vwc & vwc::PRESENT,
        vwc::PRESENT,
        "VWC must be advertised or the host never sends Flush/FUA"
    );
}

#[test]
fn get_features_reports_volatile_write_cache_enabled() {
    let addr = start_target();
    let mut admin = Client::handshake(addr, false, false);
    admin.connect(0, 32, 0xFFFF, 1);
    admin.enable_controller(2);

    let cqe = admin.get_features(spec::feat::VOLATILE_WC, 3);
    assert_eq!(
        cqe.status.get() >> 1,
        status::SUCCESS,
        "Get Features VOLATILE_WC"
    );
    assert_eq!(
        cqe.result.get() & 1,
        1,
        "VOLATILE_WC must report the cache enabled"
    );
}
