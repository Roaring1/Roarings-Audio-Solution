/// Returns the minimum packet count needed to span an observed arrival gap,
/// without adding an unnecessary extra packet for a mildly late datagram.
pub fn required_buffer_packets(
    current_packets: u8,
    safe_floor_packets: u8,
    max_packets: u8,
    arrival_interval_us: u64,
    packet_duration_us: u64,
) -> u8 {
    let max = max_packets.max(1);
    let floor = safe_floor_packets.clamp(1, max);
    if packet_duration_us == 0 {
        return current_packets.clamp(floor, max);
    }
    let needed = arrival_interval_us
        .div_ceil(packet_duration_us)
        .clamp(1, u64::from(max)) as u8;
    current_packets.clamp(floor, max).max(needed).min(max)
}

/// Raise a learned safe floor by exactly one packet per actual device
/// underrun. Callers should rate-limit this to avoid learning from a burst of
/// duplicate callbacks or a single transient stall.
pub fn next_safe_floor(current_floor: u8, max_packets: u8) -> u8 {
    current_floor
        .clamp(1, max_packets.max(1))
        .saturating_add(1)
        .min(max_packets.max(1))
}

/// Keep enough startup audio to cover both the configured packet floor and
/// the entire initial device buffer. This avoids starting a render stream with
/// a partially filled WASAPI buffer when packets are smaller than one engine buffer.
pub fn prebuffer_target_samples(
    packet_samples: usize,
    prebuffer_packets: u8,
    engine_buffer_frames: usize,
) -> usize {
    packet_samples
        .saturating_mul(usize::from(prebuffer_packets.max(1)))
        .max(engine_buffer_frames)
}

pub const SAFE_FLOOR_RELAX_AFTER_US: u64 = 600_000_000;

pub fn may_relax_safe_floor(now_us: u64, stable_since_us: u64) -> bool {
    now_us.saturating_sub(stable_since_us) >= SAFE_FLOOR_RELAX_AFTER_US
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normal_packet_timing_does_not_add_buffer() {
        assert_eq!(required_buffer_packets(2, 2, 8, 10_500, 10_667), 2);
    }

    #[test]
    fn slight_lateness_does_not_add_an_unnecessary_packet() {
        assert_eq!(required_buffer_packets(2, 2, 8, 16_000, 10_667), 2);
    }

    #[test]
    fn larger_gap_grows_to_the_mathematically_required_depth() {
        assert_eq!(required_buffer_packets(2, 2, 8, 25_000, 10_667), 3);
    }

    #[test]
    fn severe_gap_is_bounded() {
        assert_eq!(required_buffer_packets(3, 2, 8, 100_000, 10_667), 8);
    }

    #[test]
    fn underrun_increases_learned_floor_one_step() {
        assert_eq!(next_safe_floor(2, 8), 3);
        assert_eq!(next_safe_floor(7, 8), 8);
        assert_eq!(next_safe_floor(8, 8), 8);
    }

    #[test]
    fn prebuffer_target_covers_two_packets_when_that_exceeds_engine_buffer() {
        assert_eq!(prebuffer_target_samples(512, 2, 280), 1_024);
    }

    #[test]
    fn prebuffer_target_always_fills_the_initial_engine_buffer() {
        assert_eq!(prebuffer_target_samples(128, 2, 280), 280);
    }

    #[test]
    fn prebuffer_target_never_overflows_on_large_packet_counts() {
        assert_eq!(prebuffer_target_samples(usize::MAX, 8, 280), usize::MAX);
    }

    #[test]
    fn floor_only_relaxes_after_ten_minutes_stable() {
        assert!(!may_relax_safe_floor(599_999_999, 0));
        assert!(may_relax_safe_floor(600_000_000, 0));
    }
}
