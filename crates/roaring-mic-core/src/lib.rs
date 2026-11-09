//! Platform-independent primitives shared by the Linux sender and Windows receiver.
//!
//! The first migration deliberately preserves the existing 48 kHz mono S16LE
//! UDP payload. A versioned packet header can be added later without mixing
//! protocol changes into the audio-engine port.

pub mod adaptive;
pub mod gain;
pub mod pcm;

pub const SAMPLE_RATE_HZ: u32 = 48_000;
pub const CHANNELS: u16 = 1;
pub const BYTES_PER_SAMPLE: usize = 2;
pub const MAX_PCM_DATAGRAM_BYTES: usize = 8_192;
