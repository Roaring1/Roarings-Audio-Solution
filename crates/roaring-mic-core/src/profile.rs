//! Strict, versioned persistence for a learned Windows audio queue floor.
//!
//! The profile key includes the peer, render endpoint identity, sample rate,
//! requested WASAPI period, actual engine buffer and packet size. A value
//! learned under a different device or transport profile must never be reused.

use std::collections::BTreeMap;

const PROFILE_VERSION: &str = "1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueProfileKey {
    pub peer_ip: String,
    pub listen_addr: String,
    pub device_id: String,
    pub sample_rate_hz: u32,
    pub period_frames: u32,
    pub engine_buffer_frames: u32,
    pub packet_bytes: usize,
}

fn encode_hex(value: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(value.len() * 2);
    for byte in value.as_bytes() {
        encoded.push(HEX[(byte >> 4) as usize] as char);
        encoded.push(HEX[(byte & 0x0f) as usize] as char);
    }
    encoded
}

fn decode_hex(value: &str) -> Option<String> {
    if !value.len().is_multiple_of(2) {
        return None;
    }
    let mut bytes = Vec::with_capacity(value.len() / 2);
    for pair in value.as_bytes().chunks_exact(2) {
        let high = (pair[0] as char).to_digit(16)? as u8;
        let low = (pair[1] as char).to_digit(16)? as u8;
        bytes.push((high << 4) | low);
    }
    String::from_utf8(bytes).ok()
}

/// Encode a floor to a small line-oriented state file. Device IDs are hex
/// encoded so path separators, equals signs or newlines cannot alter fields.
pub fn encode_queue_profile(key: &QueueProfileKey, safe_floor_packets: u8) -> String {
    format!(
        "version={PROFILE_VERSION}\npeer_ip={}\nlisten_addr={}\ndevice_id_hex={}\nsample_rate_hz={}\nperiod_frames={}\nengine_buffer_frames={}\npacket_bytes={}\nsafe_floor_packets={}\n",
        key.peer_ip,
        key.listen_addr,
        encode_hex(&key.device_id),
        key.sample_rate_hz,
        key.period_frames,
        key.engine_buffer_frames,
        key.packet_bytes,
        safe_floor_packets
    )
}

/// Return a saved floor only if the entire key matches and the data is valid.
/// Invalid, partial, old-version or mismatched files fail closed to the
/// caller's configured default.
pub fn decode_queue_profile(
    contents: &str,
    expected_key: &QueueProfileKey,
    max_packets: u8,
) -> Option<u8> {
    let mut fields = BTreeMap::new();
    for line in contents.lines() {
        let (name, value) = line.split_once('=')?;
        if fields.insert(name, value).is_some() {
            return None;
        }
    }
    if fields.len() != 9 || fields.get("version")? != &PROFILE_VERSION {
        return None;
    }

    let peer_ip = *fields.get("peer_ip")?;
    let listen_addr = *fields.get("listen_addr")?;
    let device_id = decode_hex(fields.get("device_id_hex")?)?;
    let sample_rate_hz = fields.get("sample_rate_hz")?.parse::<u32>().ok()?;
    let period_frames = fields.get("period_frames")?.parse::<u32>().ok()?;
    let engine_buffer_frames = fields.get("engine_buffer_frames")?.parse::<u32>().ok()?;
    let packet_bytes = fields.get("packet_bytes")?.parse::<usize>().ok()?;
    let safe_floor_packets = fields.get("safe_floor_packets")?.parse::<u8>().ok()?;

    if peer_ip != expected_key.peer_ip
        || listen_addr != expected_key.listen_addr
        || device_id != expected_key.device_id
        || sample_rate_hz != expected_key.sample_rate_hz
        || period_frames != expected_key.period_frames
        || engine_buffer_frames != expected_key.engine_buffer_frames
        || packet_bytes != expected_key.packet_bytes
        || !(1..=max_packets.max(1)).contains(&safe_floor_packets)
    {
        return None;
    }
    Some(safe_floor_packets)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> QueueProfileKey {
        QueueProfileKey {
            peer_ip: "192.168.50.123".to_owned(),
            listen_addr: "0.0.0.0:46003".to_owned(),
            device_id: "CABLE\\Input={endpoint}\nunique".to_owned(),
            sample_rate_hz: 48_000,
            period_frames: 128,
            engine_buffer_frames: 280,
            packet_bytes: 1_024,
        }
    }

    #[test]
    fn profile_round_trips_and_escapes_endpoint_identity() {
        let key = key();
        let contents = encode_queue_profile(&key, 5);
        assert!(!contents.contains("unique\n"));
        assert_eq!(decode_queue_profile(&contents, &key, 8), Some(5));
    }

    #[test]
    fn profile_is_not_reused_for_another_peer() {
        let key = key();
        let contents = encode_queue_profile(&key, 5);
        let mut other = key.clone();
        other.peer_ip = "192.168.50.124".to_owned();
        assert_eq!(decode_queue_profile(&contents, &other, 8), None);
    }

    #[test]
    fn profile_is_not_reused_for_another_local_listen_endpoint() {
        let key = key();
        let contents = encode_queue_profile(&key, 5);
        let mut other = key.clone();
        other.listen_addr = "0.0.0.0:46001".to_owned();
        assert_eq!(decode_queue_profile(&contents, &other, 8), None);
    }

    #[test]
    fn profile_is_not_reused_for_another_endpoint_or_engine_period() {
        let key = key();
        let contents = encode_queue_profile(&key, 5);
        let mut other_device = key.clone();
        other_device.device_id.push_str("-other");
        assert_eq!(decode_queue_profile(&contents, &other_device, 8), None);
        let mut other_period = key.clone();
        other_period.period_frames = 256;
        assert_eq!(decode_queue_profile(&contents, &other_period, 8), None);
    }

    #[test]
    fn profile_is_not_reused_when_packet_shape_or_rate_changes() {
        let key = key();
        let contents = encode_queue_profile(&key, 5);
        let mut other_packet = key.clone();
        other_packet.packet_bytes = 960;
        assert_eq!(decode_queue_profile(&contents, &other_packet, 8), None);
        let mut other_rate = key.clone();
        other_rate.sample_rate_hz = 44_100;
        assert_eq!(decode_queue_profile(&contents, &other_rate, 8), None);
    }

    #[test]
    fn corrupt_partial_duplicate_and_out_of_range_profiles_fail_closed() {
        let key = key();
        assert_eq!(
            decode_queue_profile("version=1\nsafe_floor_packets=7", &key, 8),
            None
        );
        let duplicate = format!("{}safe_floor_packets=2\n", encode_queue_profile(&key, 5));
        assert_eq!(decode_queue_profile(&duplicate, &key, 8), None);
        assert_eq!(
            decode_queue_profile(&encode_queue_profile(&key, 9), &key, 8),
            None
        );
        assert_eq!(
            decode_queue_profile(&encode_queue_profile(&key, 0), &key, 8),
            None
        );
    }
}
