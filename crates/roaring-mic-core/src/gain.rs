/// Applies the configured percentage gain to one S16LE sample.
///
/// The common 100% path is bit-exact. Values above 100% saturate instead of
/// wrapping, and the caller receives a clipping flag for telemetry.
#[inline]
pub fn scale_sample(sample: i16, gain_percent: u16) -> (i16, bool) {
    if gain_percent == 100 {
        return (sample, false);
    }
    if gain_percent == 0 {
        return (0, false);
    }

    let amplified = (i32::from(sample) * i32::from(gain_percent)) / 100;
    let clipped = !(i32::from(i16::MIN)..=i32::from(i16::MAX)).contains(&amplified);
    (
        amplified.clamp(i32::from(i16::MIN), i32::from(i16::MAX)) as i16,
        clipped,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_gain_is_silence() {
        assert_eq!(scale_sample(12_345, 0), (0, false));
        assert_eq!(scale_sample(i16::MIN, 0), (0, false));
    }

    #[test]
    fn unity_gain_is_bit_exact() {
        for sample in [i16::MIN, -1234, -1, 0, 1, 1234, i16::MAX] {
            assert_eq!(scale_sample(sample, 100), (sample, false));
        }
    }

    #[test]
    fn two_hundred_percent_gain_saturates_and_reports_clipping() {
        assert_eq!(scale_sample(20_000, 200), (i16::MAX, true));
        assert_eq!(scale_sample(-20_000, 200), (i16::MIN, true));
        assert_eq!(scale_sample(100, 200), (200, false));
    }
}
