use crate::{BYTES_PER_SAMPLE, MAX_PCM_DATAGRAM_BYTES, SAMPLE_RATE_HZ};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PacketError {
    Empty,
    OddByteCount,
    TooLarge,
}

/// A validated legacy PCM datagram. Samples remain borrowed and are decoded
/// little-endian on demand, so parsing never allocates or copies audio data.
#[derive(Debug, Clone, Copy)]
pub struct RawPcmPacket<'a> {
    bytes: &'a [u8],
}

impl<'a> RawPcmPacket<'a> {
    pub fn parse(bytes: &'a [u8]) -> Result<Self, PacketError> {
        if bytes.is_empty() {
            return Err(PacketError::Empty);
        }
        if bytes.len() > MAX_PCM_DATAGRAM_BYTES {
            return Err(PacketError::TooLarge);
        }
        if !bytes.len().is_multiple_of(BYTES_PER_SAMPLE) {
            return Err(PacketError::OddByteCount);
        }
        Ok(Self { bytes })
    }

    #[inline]
    pub const fn sample_rate_hz(&self) -> u32 {
        SAMPLE_RATE_HZ
    }

    #[inline]
    pub const fn frames(&self) -> usize {
        self.bytes.len() / BYTES_PER_SAMPLE
    }

    #[inline]
    pub const fn payload_bytes(&self) -> &'a [u8] {
        self.bytes
    }

    #[inline]
    pub fn sample(&self, index: usize) -> Option<i16> {
        let offset = index.checked_mul(BYTES_PER_SAMPLE)?;
        let pair = self.bytes.get(offset..offset + BYTES_PER_SAMPLE)?;
        Some(i16::from_le_bytes([pair[0], pair[1]]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_current_1024_byte_packet_as_512_frames() {
        let bytes = vec![0_u8; 1_024];
        let packet = RawPcmPacket::parse(&bytes).unwrap();
        assert_eq!(packet.sample_rate_hz(), 48_000);
        assert_eq!(packet.frames(), 512);
        assert_eq!(packet.sample(0), Some(0));
    }

    #[test]
    fn decodes_signed_little_endian_samples() {
        let bytes = [0x00, 0x80, 0xff, 0x7f, 0x34, 0x12];
        let packet = RawPcmPacket::parse(&bytes).unwrap();
        assert_eq!(packet.sample(0), Some(i16::MIN));
        assert_eq!(packet.sample(1), Some(i16::MAX));
        assert_eq!(packet.sample(2), Some(0x1234));
        assert_eq!(packet.sample(3), None);
    }

    #[test]
    fn rejects_empty_odd_and_oversized_datagrams() {
        assert_eq!(RawPcmPacket::parse(&[]).unwrap_err(), PacketError::Empty);
        assert_eq!(
            RawPcmPacket::parse(&[0]).unwrap_err(),
            PacketError::OddByteCount
        );
        assert_eq!(
            RawPcmPacket::parse(&vec![0; MAX_PCM_DATAGRAM_BYTES + 2]).unwrap_err(),
            PacketError::TooLarge
        );
    }
}
