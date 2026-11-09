//! Windows UDP-to-WASAPI receiver candidate.
//!
//! The production PowerShell/C# WaveOut receiver remains the fallback. This
//! candidate preserves the 48 kHz mono S16LE UDP wire format, and defaults to
//! silent output so a parallel test cannot duplicate the live microphone.

use std::error::Error;
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use roaring_mic_core::adaptive::{next_safe_floor, prebuffer_target_samples};
use roaring_mic_core::gain::scale_sample;
use roaring_mic_core::pcm::RawPcmPacket;
use roaring_mic_core::{MAX_PCM_DATAGRAM_BYTES, SAMPLE_RATE_HZ};
use rtrb::{Consumer, Producer, RingBuffer};
use socket2::{Domain, Protocol, SockAddr, Socket, Type};
use wasapi::{
    deinitialize, initialize_mta, AudioClient, AudioClientProperties, Device, DeviceEnumerator,
    Direction, SampleType, StreamCategory, TimingMode, WasapiError,
};
use windows::core::PCWSTR;
use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::Threading::{
    AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW, AvSetMmThreadPriority,
    GetCurrentThread, SetThreadPriority, AVRT_PRIORITY_HIGH, THREAD_PRIORITY_ABOVE_NORMAL,
    THREAD_PRIORITY_NORMAL,
};

const DEFAULT_DEVICE_NEEDLE: &str = "CABLE Input";
const DEFAULT_LISTEN: &str = "0.0.0.0:46003";
const DEFAULT_PEER: &str = "192.168.50.123";
const DEFAULT_PERIOD_FRAMES: u32 = 128;
const DEFAULT_PREBUFFER_PACKETS: u8 = 2;
const MAX_PREBUFFER_PACKETS: u8 = 8;
const QUEUE_CAPACITY_SAMPLES: usize = 8_192;
const MAX_QUEUED_PACKETS: usize = 4;
const UDP_RECEIVE_BUFFER_BYTES: usize = 4_096;
const STARTUP_TIMEOUT: Duration = Duration::from_secs(5);
const UDP_READ_TIMEOUT: Duration = Duration::from_millis(100);
const EVENT_TIMEOUT_MS: u32 = 100;
const MAX_CONSECUTIVE_EVENT_TIMEOUTS: u32 = 20;
const FLOOR_RAISE_INTERVAL: Duration = Duration::from_secs(5);

struct ComApartment;

impl ComApartment {
    fn initialize() -> Result<Self, Box<dyn Error>> {
        initialize_mta().ok()?;
        Ok(Self)
    }
}

impl Drop for ComApartment {
    fn drop(&mut self) {
        deinitialize();
    }
}

struct MmcssRegistration {
    handle: Option<HANDLE>,
    fallback: bool,
    mode: &'static str,
}

impl MmcssRegistration {
    fn enter() -> Self {
        for (task_name, mode) in [("Pro Audio", "Pro Audio"), ("Audio", "Audio fallback")] {
            let wide: Vec<u16> = task_name.encode_utf16().chain(Some(0)).collect();
            let mut task_index = 0_u32;
            if let Ok(handle) =
                unsafe { AvSetMmThreadCharacteristicsW(PCWSTR(wide.as_ptr()), &mut task_index) }
            {
                let _ = unsafe { AvSetMmThreadPriority(handle, AVRT_PRIORITY_HIGH) };
                return Self {
                    handle: Some(handle),
                    fallback: false,
                    mode,
                };
            }
        }
        let _ = unsafe { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL) };
        Self {
            handle: None,
            fallback: true,
            mode: "AboveNormal fallback",
        }
    }

    fn mode(&self) -> &'static str {
        self.mode
    }
}

impl Drop for MmcssRegistration {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            let _ = unsafe { AvRevertMmThreadCharacteristics(handle) };
        } else if self.fallback {
            let _ = unsafe { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_NORMAL) };
            self.fallback = false;
        }
    }
}

struct UdpWorker {
    stop: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
}

impl UdpWorker {
    fn shutdown(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

impl Drop for UdpWorker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

struct StartedStream<'a>(&'a AudioClient);

impl Drop for StartedStream<'_> {
    fn drop(&mut self) {
        let _ = self.0.stop_stream();
    }
}

#[derive(Debug, Clone)]
struct Config {
    listen: SocketAddr,
    peer: IpAddr,
    device_needle: String,
    period_frames: u32,
    prebuffer_packets: u8,
    duration: Option<Duration>,
    gain_percent: u16,
    render_audio: bool,
}

impl Config {
    fn parse(args: &[String]) -> Result<Self, Box<dyn Error>> {
        let mut config = Self {
            listen: DEFAULT_LISTEN.parse()?,
            peer: DEFAULT_PEER.parse()?,
            device_needle: std::env::var("ROARING_MIC_DEVICE")
                .unwrap_or_else(|_| DEFAULT_DEVICE_NEEDLE.to_owned()),
            period_frames: DEFAULT_PERIOD_FRAMES,
            prebuffer_packets: DEFAULT_PREBUFFER_PACKETS,
            duration: Some(Duration::from_secs(30)),
            gain_percent: 100,
            render_audio: false,
        };

        for arg in args {
            if let Some(value) = arg.strip_prefix("--listen=") {
                config.listen = value.parse()?;
            } else if let Some(value) = arg.strip_prefix("--peer=") {
                config.peer = value.parse()?;
            } else if let Some(value) = arg.strip_prefix("--device=") {
                config.device_needle = value.to_owned();
            } else if let Some(value) = arg.strip_prefix("--period=") {
                config.period_frames = value.parse()?;
            } else if let Some(value) = arg.strip_prefix("--prebuffer=") {
                config.prebuffer_packets = value.parse()?;
            } else if let Some(value) = arg.strip_prefix("--seconds=") {
                let seconds: u64 = value.parse()?;
                config.duration = (seconds > 0).then(|| Duration::from_secs(seconds));
            } else if let Some(value) = arg.strip_prefix("--gain=") {
                config.gain_percent = value.parse()?;
            } else if arg == "--render" {
                config.render_audio = true;
            } else if arg == "--silent" || arg == "--udp" {
                // Silent output is the default. --udp is an explicit mode marker.
            } else {
                return Err(format!("unknown argument: {arg}").into());
            }
        }

        if !matches!(config.listen, SocketAddr::V4(_)) {
            return Err("only IPv4 UDP listen addresses are currently supported".into());
        }
        if config.device_needle.trim().is_empty() {
            return Err("device match cannot be empty".into());
        }
        if !(1..=MAX_PREBUFFER_PACKETS).contains(&config.prebuffer_packets) {
            return Err(
                format!("prebuffer must be between 1 and {MAX_PREBUFFER_PACKETS} packets").into(),
            );
        }
        if config.gain_percent > 200 {
            return Err("gain must be between 0 and 200 percent".into());
        }
        if config.period_frames == 0 {
            return Err("period must be greater than zero".into());
        }
        Ok(config)
    }
}

#[derive(Default)]
struct Metrics {
    received_packets: AtomicU64,
    received_samples: AtomicU64,
    rejected_sources: AtomicU64,
    rejected_packets: AtomicU64,
    packet_size_changes: AtomicU64,
    queue_dropped_packets: AtomicU64,
    stale_samples_discarded: AtomicU64,
    underrun_events: AtomicU64,
    underrun_frames: AtomicU64,
    rendered_frames: AtomicU64,
    clipped_samples: AtomicU64,
    event_count: AtomicU64,
    event_timeouts: AtomicU64,
    max_queue_samples: AtomicUsize,
    last_packet_samples: AtomicUsize,
    expected_packet_bytes: AtomicUsize,
    max_arrival_interval_us: AtomicU64,
    max_event_interval_us: AtomicU64,
    safe_floor_packets: AtomicUsize,
}

fn update_max_us(target: &AtomicU64, value: u64) {
    target.fetch_max(value, Ordering::Relaxed);
}

fn update_max_samples(target: &AtomicUsize, value: usize) {
    target.fetch_max(value, Ordering::Relaxed);
}

fn set_udp_worker_priority() {
    let _ = unsafe { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL) };
}

fn find_render_device(needle: &str) -> Result<Device, Box<dyn Error>> {
    let enumerator = DeviceEnumerator::new()?;
    let devices = enumerator.get_device_collection(Direction::Render)?;
    for device_result in &devices {
        let device = device_result?;
        let name = device.get_friendlyname()?;
        if name
            .to_ascii_lowercase()
            .contains(&needle.to_ascii_lowercase())
        {
            return Ok(device);
        }
    }
    Err(format!("no active render endpoint matched '{needle}'").into())
}

fn open_target(needle: &str) -> Result<(Device, AudioClient, wasapi::WaveFormat), Box<dyn Error>> {
    let device = find_render_device(needle)?;
    let client = device.get_iaudioclient()?;
    let mix = client.get_mixformat()?;
    Ok((device, client, mix))
}

fn print_capabilities(
    device: &Device,
    mix: &wasapi::WaveFormat,
    period: wasapi::SharedModeEnginePeriod,
) -> Result<(), Box<dyn Error>> {
    let name = device.get_friendlyname()?;
    let id = device.get_id()?;
    let rate = mix.get_samplespersec();
    let to_ms = |frames: u32| f64::from(frames) * 1_000.0 / f64::from(rate);

    println!("DEVICE={name}");
    println!("DEVICE_ID={id}");
    println!(
        "MIX_FORMAT={}Hz/{}ch/{}bit/{:?}/block_align={}",
        rate,
        mix.get_nchannels(),
        mix.get_bitspersample(),
        mix.get_subformat()?,
        mix.get_blockalign()
    );
    println!(
        "SHARED_PERIODS default={} ({:.3}ms) fundamental={} ({:.3}ms) min={} ({:.3}ms) max={} ({:.3}ms)",
        period.default,
        to_ms(period.default),
        period.fundamental,
        to_ms(period.fundamental),
        period.min,
        to_ms(period.min),
        period.max,
        to_ms(period.max)
    );
    Ok(())
}

fn probe_device(needle: &str) -> Result<(), Box<dyn Error>> {
    let (device, client, mix) = open_target(needle)?;
    let period = client.get_shared_mode_engine_period(&mix)?;
    print_capabilities(&device, &mix, period)?;
    println!("PROBE_ONLY=true STREAM_INITIALIZED=false");
    println!("NOTE=period query only; no samples rendered and no endpoint settings changed");
    Ok(())
}

fn silent_render_probe(
    needle: &str,
    seconds: u64,
    requested_period: Option<u32>,
) -> Result<(), Box<dyn Error>> {
    let (device, mut client, mix) = open_target(needle)?;
    client.set_properties(AudioClientProperties::new().set_category(StreamCategory::Other))?;
    let periods = client.get_shared_mode_engine_period(&mix)?;
    let period_frames = requested_period.unwrap_or(periods.min);
    validate_mix_format(&mix)?;
    validate_period(period_frames, periods)?;
    client.initialize_shared_audio_stream(&mix, TimingMode::Events, period_frames)?;
    let event_handle = client.set_get_eventhandle()?;
    let render = client.get_audiorenderclient()?;
    let buffer_frames = client.get_buffer_size()?;
    let block_align = mix.get_blockalign() as usize;

    let _mmcss = MmcssRegistration::enter();
    let initial_frames = client.get_available_space_in_frames()? as usize;
    let silence = vec![0_u8; initial_frames * block_align];
    if !silence.is_empty() {
        render.write_to_device(&silence, None)?;
    }
    client.start_stream()?;
    let _stream = StartedStream(&client);

    let mut intervals_ms = Vec::with_capacity(seconds as usize * 600);
    let silence = vec![0_u8; buffer_frames as usize * block_align];
    let mut timeout_count = 0_u64;
    let mut event_count = 0_u64;
    let mut empty_writes = 0_u64;
    let mut previous = Instant::now();
    let started = Instant::now();

    while started.elapsed() < Duration::from_secs(seconds) {
        match event_handle.wait_for_event(500) {
            Ok(()) => {
                let now = Instant::now();
                intervals_ms.push(now.duration_since(previous).as_secs_f64() * 1_000.0);
                previous = now;
                event_count += 1;
                let available = client.get_available_space_in_frames()? as usize;
                if available == 0 {
                    empty_writes += 1;
                } else {
                    render.write_to_device(&silence[..available * block_align], None)?;
                }
            }
            Err(WasapiError::EventTimeout) => timeout_count += 1,
            Err(error) => return Err(Box::new(error)),
        }
    }

    drop(_stream);
    intervals_ms.sort_by(f64::total_cmp);
    let percentile = |p: f64| -> f64 {
        if intervals_ms.is_empty() {
            return 0.0;
        }
        let index = ((p * intervals_ms.len() as f64).ceil() as usize).saturating_sub(1);
        intervals_ms[index.min(intervals_ms.len() - 1)]
    };
    println!(
        "DEVICE={} PERIOD_FRAMES={} PERIOD_MS={:.3} BUFFER_FRAMES={} BUFFER_MS={:.3}",
        device.get_friendlyname()?,
        period_frames,
        f64::from(period_frames) * 1_000.0 / f64::from(SAMPLE_RATE_HZ),
        buffer_frames,
        f64::from(buffer_frames) * 1_000.0 / f64::from(SAMPLE_RATE_HZ)
    );
    println!("EVENTS={event_count} TIMEOUTS={timeout_count} EMPTY_WRITES={empty_writes}");
    println!(
        "EVENT_MS median={:.3} p95={:.3} p99={:.3} max={:.3}",
        percentile(0.50),
        percentile(0.95),
        percentile(0.99),
        intervals_ms.last().copied().unwrap_or(0.0)
    );
    println!("MMCSS_MODE={}", _mmcss.mode());
    println!("AUDIO_PAYLOAD=silent; no microphone samples injected");
    Ok(())
}

fn validate_mix_format(mix: &wasapi::WaveFormat) -> Result<(), Box<dyn Error>> {
    if mix.get_samplespersec() != SAMPLE_RATE_HZ
        || mix.get_subformat()? != SampleType::Float
        || mix.get_bitspersample() != 32
        || mix.get_nchannels() != 2
        || mix.get_blockalign() != 8
    {
        return Err(format!(
            "candidate expects 48 kHz stereo 32-bit-float mix format; endpoint reports {} Hz, {} channels, {} bit, {:?}, block align {}",
            mix.get_samplespersec(),
            mix.get_nchannels(),
            mix.get_bitspersample(),
            mix.get_subformat()?,
            mix.get_blockalign()
        ).into());
    }
    Ok(())
}

fn validate_period(
    requested: u32,
    periods: wasapi::SharedModeEnginePeriod,
) -> Result<(), Box<dyn Error>> {
    if requested < periods.min
        || requested > periods.max
        || periods.fundamental == 0
        || !(requested - periods.min).is_multiple_of(periods.fundamental)
    {
        return Err(format!(
            "requested period {requested} is not supported; valid range {}..={} with fundamental {}",
            periods.min, periods.max, periods.fundamental
        ).into());
    }
    Ok(())
}

fn make_udp_socket(listen: SocketAddr) -> Result<UdpSocket, Box<dyn Error>> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_recv_buffer_size(UDP_RECEIVE_BUFFER_BYTES)?;
    socket.bind(&SockAddr::from(listen))?;
    let socket: UdpSocket = socket.into();
    socket.set_read_timeout(Some(UDP_READ_TIMEOUT))?;
    Ok(socket)
}

fn spawn_udp_worker(
    socket: UdpSocket,
    expected_peer: IpAddr,
    mut producer: Producer<i16>,
    stop: Arc<AtomicBool>,
    metrics: Arc<Metrics>,
) -> Result<JoinHandle<()>, Box<dyn Error>> {
    let worker = thread::Builder::new()
        .name("RoaringMic UDP receive".to_owned())
        .spawn(move || {
            set_udp_worker_priority();
            let mut datagram = [0_u8; MAX_PCM_DATAGRAM_BYTES + 1];
            let mut previous_arrival: Option<Instant> = None;
            while !stop.load(Ordering::Acquire) {
                let (length, source) = match socket.recv_from(&mut datagram) {
                    Ok(result) => result,
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            || error.kind() == std::io::ErrorKind::TimedOut =>
                    {
                        continue;
                    }
                    Err(error) => {
                        eprintln!("UDP receive stopped: {error}");
                        break;
                    }
                };

                if source.ip() != expected_peer {
                    metrics.rejected_sources.fetch_add(1, Ordering::Relaxed);
                    continue;
                }

                let packet = match RawPcmPacket::parse(&datagram[..length]) {
                    Ok(packet) => packet,
                    Err(_) => {
                        metrics.rejected_packets.fetch_add(1, Ordering::Relaxed);
                        continue;
                    }
                };
                let previous_size = metrics.expected_packet_bytes.load(Ordering::Relaxed);
                if previous_size == 0 {
                    metrics
                        .expected_packet_bytes
                        .store(length, Ordering::Relaxed);
                } else if previous_size != length {
                    metrics.packet_size_changes.fetch_add(1, Ordering::Relaxed);
                    metrics.rejected_packets.fetch_add(1, Ordering::Relaxed);
                    continue;
                }

                let samples = packet.frames();
                if producer.slots() < samples {
                    metrics
                        .queue_dropped_packets
                        .fetch_add(1, Ordering::Relaxed);
                    continue;
                }
                for index in 0..samples {
                    let Some(sample) = packet.sample(index) else {
                        metrics.rejected_packets.fetch_add(1, Ordering::Relaxed);
                        break;
                    };
                    if producer.push(sample).is_err() {
                        metrics
                            .queue_dropped_packets
                            .fetch_add(1, Ordering::Relaxed);
                        break;
                    }
                }

                metrics.received_packets.fetch_add(1, Ordering::Relaxed);
                metrics
                    .received_samples
                    .fetch_add(samples as u64, Ordering::Relaxed);
                metrics
                    .last_packet_samples
                    .store(samples, Ordering::Relaxed);
                update_max_samples(
                    &metrics.max_queue_samples,
                    QUEUE_CAPACITY_SAMPLES - producer.slots(),
                );

                let now = Instant::now();
                if let Some(previous) = previous_arrival.replace(now) {
                    update_max_us(
                        &metrics.max_arrival_interval_us,
                        now.duration_since(previous).as_micros() as u64,
                    );
                }
            }
        })?;
    Ok(worker)
}

fn fill_render_buffer(
    output: &mut [u8],
    frames: usize,
    consumer: &mut Consumer<i16>,
    gain_percent: u16,
    render_audio: bool,
) -> (u64, u64, u64) {
    let mut missing_frames = 0_u64;
    let mut rendered_frames = 0_u64;
    let mut clipped_samples = 0_u64;
    for frame_index in 0..frames {
        let sample = match consumer.pop() {
            Ok(sample) => {
                rendered_frames += 1;
                sample
            }
            Err(_) => {
                missing_frames += 1;
                0
            }
        };
        let (scaled, clipped) = scale_sample(sample, gain_percent);
        if clipped {
            clipped_samples += 1;
        }
        let value = if render_audio {
            f32::from(scaled) / 32_768.0
        } else {
            0.0
        };
        let bytes = value.to_le_bytes();
        let offset = frame_index * 8;
        output[offset..offset + 4].copy_from_slice(&bytes);
        output[offset + 4..offset + 8].copy_from_slice(&bytes);
    }
    (missing_frames, rendered_frames, clipped_samples)
}

fn run_udp(config: Config) -> Result<(), Box<dyn Error>> {
    let (device, mut client, mix) = open_target(&config.device_needle)?;
    client.set_properties(AudioClientProperties::new().set_category(StreamCategory::Other))?;
    validate_mix_format(&mix)?;
    let periods = client.get_shared_mode_engine_period(&mix)?;
    validate_period(config.period_frames, periods)?;
    client.initialize_shared_audio_stream(&mix, TimingMode::Events, config.period_frames)?;
    let event_handle = client.set_get_eventhandle()?;
    let render = client.get_audiorenderclient()?;
    let buffer_frames = client.get_buffer_size()?;

    let socket = make_udp_socket(config.listen)?;
    let (producer, mut consumer) = RingBuffer::<i16>::new(QUEUE_CAPACITY_SAMPLES);
    let stop = Arc::new(AtomicBool::new(false));
    let metrics = Arc::new(Metrics::default());
    metrics
        .safe_floor_packets
        .store(config.prebuffer_packets as usize, Ordering::Relaxed);
    let receiver_thread =
        spawn_udp_worker(socket, config.peer, producer, stop.clone(), metrics.clone())?;
    let mut receiver = UdpWorker {
        stop,
        join: Some(receiver_thread),
    };

    let startup_deadline = Instant::now() + STARTUP_TIMEOUT;
    let mut packet_samples = 0_usize;
    let mut target_samples = 0_usize;
    while Instant::now() < startup_deadline {
        packet_samples = metrics.last_packet_samples.load(Ordering::Relaxed);
        if packet_samples > 0 {
            target_samples = prebuffer_target_samples(
                packet_samples,
                config.prebuffer_packets,
                buffer_frames as usize,
            );
            if consumer.slots() >= target_samples {
                break;
            }
        }
        thread::sleep(Duration::from_millis(1));
    }
    if packet_samples == 0 || consumer.slots() < target_samples {
        return Err(format!(
            "startup queue timed out: have {} samples, need {target_samples}",
            consumer.slots()
        )
        .into());
    }

    let mut output = vec![0_u8; buffer_frames as usize * 8];
    let initial_frames = client.get_available_space_in_frames()? as usize;
    let (missing, rendered, clipped) = fill_render_buffer(
        &mut output,
        initial_frames,
        &mut consumer,
        config.gain_percent,
        config.render_audio,
    );
    metrics
        .underrun_frames
        .fetch_add(missing, Ordering::Relaxed);
    metrics
        .rendered_frames
        .fetch_add(rendered, Ordering::Relaxed);
    metrics
        .clipped_samples
        .fetch_add(clipped, Ordering::Relaxed);
    if initial_frames > 0 {
        render.write_to_device(&output[..initial_frames * 8], None)?;
    }

    let _mmcss = MmcssRegistration::enter();
    client.start_stream()?;
    let _stream = StartedStream(&client);
    println!(
        "WASAPI_UDP_STARTED device=\"{}\" peer={} listen={} period={} frames ({:.3}ms) engine_buffer={} frames ({:.3}ms) prebuffer={} packets target={} samples queue_capacity={} samples gain={} render_audio={} mmcss={}",
        device.get_friendlyname()?,
        config.peer,
        config.listen,
        config.period_frames,
        f64::from(config.period_frames) * 1_000.0 / f64::from(SAMPLE_RATE_HZ),
        buffer_frames,
        f64::from(buffer_frames) * 1_000.0 / f64::from(SAMPLE_RATE_HZ),
        config.prebuffer_packets,
        target_samples,
        QUEUE_CAPACITY_SAMPLES,
        config.gain_percent,
        config.render_audio,
        _mmcss.mode()
    );

    let started = Instant::now();
    let mut last_event = Instant::now();
    let mut last_floor_raise = Instant::now() - FLOOR_RAISE_INTERVAL;
    let mut safe_floor = config.prebuffer_packets;
    let mut primed = true;
    let mut consecutive_timeouts = 0_u32;
    let mut max_consecutive_timeouts = 0_u32;
    let result: Result<(), Box<dyn Error>> = loop {
        if config
            .duration
            .is_some_and(|duration| started.elapsed() >= duration)
        {
            break Ok(());
        }
        match event_handle.wait_for_event(EVENT_TIMEOUT_MS) {
            Ok(()) => consecutive_timeouts = 0,
            Err(WasapiError::EventTimeout) => {
                metrics.event_timeouts.fetch_add(1, Ordering::Relaxed);
                consecutive_timeouts += 1;
                max_consecutive_timeouts = max_consecutive_timeouts.max(consecutive_timeouts);
                if consecutive_timeouts >= MAX_CONSECUTIVE_EVENT_TIMEOUTS {
                    break Err("WASAPI event timeout threshold reached".into());
                }
                continue;
            }
            Err(error) => break Err(Box::new(error)),
        }
        metrics.event_count.fetch_add(1, Ordering::Relaxed);
        let now = Instant::now();
        update_max_us(
            &metrics.max_event_interval_us,
            now.duration_since(last_event).as_micros() as u64,
        );
        last_event = now;

        let queued = consumer.slots();
        let max_queue = packet_samples.saturating_mul(MAX_QUEUED_PACKETS);
        if queued > max_queue {
            let mut to_discard = queued - max_queue;
            while to_discard > 0 && consumer.pop().is_ok() {
                to_discard -= 1;
            }
            metrics
                .stale_samples_discarded
                .fetch_add((queued - max_queue - to_discard) as u64, Ordering::Relaxed);
        }

        if !primed && consumer.slots() >= target_samples {
            primed = true;
        }
        let available = client.get_available_space_in_frames()? as usize;
        if available == 0 {
            continue;
        }
        if !primed {
            output[..available * 8].fill(0);
            render.write_to_device(&output[..available * 8], None)?;
            continue;
        }

        let (missing, rendered, clipped) = fill_render_buffer(
            &mut output,
            available,
            &mut consumer,
            config.gain_percent,
            config.render_audio,
        );
        metrics
            .rendered_frames
            .fetch_add(rendered, Ordering::Relaxed);
        metrics
            .clipped_samples
            .fetch_add(clipped, Ordering::Relaxed);
        if missing > 0 {
            metrics.underrun_events.fetch_add(1, Ordering::Relaxed);
            metrics
                .underrun_frames
                .fetch_add(missing, Ordering::Relaxed);
            primed = false;
            if now.duration_since(last_floor_raise) >= FLOOR_RAISE_INTERVAL
                && safe_floor < MAX_PREBUFFER_PACKETS
            {
                safe_floor = next_safe_floor(safe_floor, MAX_PREBUFFER_PACKETS);
                target_samples =
                    prebuffer_target_samples(packet_samples, safe_floor, buffer_frames as usize);
                metrics
                    .safe_floor_packets
                    .store(safe_floor as usize, Ordering::Relaxed);
                last_floor_raise = now;
                eprintln!(
                    "WASAPI_REPRIME reason=output-underrun floor={} packets target={} samples",
                    safe_floor, target_samples
                );
            }
        }
        render.write_to_device(&output[..available * 8], None)?;
    };

    drop(_stream);
    receiver.shutdown();
    println!(
        "WASAPI_UDP_RESULT packets={} samples={} rejected_sources={} rejected_packets={} packet_size_changes={} queue_dropped={} stale_samples_discarded={} underrun_events={} underrun_frames={} rendered_frames={} clipped_samples={} events={} event_timeouts={} max_consecutive_timeouts={} max_queue_samples={} max_queue_ms={:.3} max_arrival_ms={:.3} max_event_ms={:.3} final_safe_floor={} packet_bytes={}",
        metrics.received_packets.load(Ordering::Relaxed),
        metrics.received_samples.load(Ordering::Relaxed),
        metrics.rejected_sources.load(Ordering::Relaxed),
        metrics.rejected_packets.load(Ordering::Relaxed),
        metrics.packet_size_changes.load(Ordering::Relaxed),
        metrics.queue_dropped_packets.load(Ordering::Relaxed),
        metrics.stale_samples_discarded.load(Ordering::Relaxed),
        metrics.underrun_events.load(Ordering::Relaxed),
        metrics.underrun_frames.load(Ordering::Relaxed),
        metrics.rendered_frames.load(Ordering::Relaxed),
        metrics.clipped_samples.load(Ordering::Relaxed),
        metrics.event_count.load(Ordering::Relaxed),
        metrics.event_timeouts.load(Ordering::Relaxed),
        max_consecutive_timeouts,
        metrics.max_queue_samples.load(Ordering::Relaxed),
        metrics.max_queue_samples.load(Ordering::Relaxed) as f64 * 1_000.0
            / f64::from(SAMPLE_RATE_HZ),
        metrics.max_arrival_interval_us.load(Ordering::Relaxed) as f64 / 1_000.0,
        metrics.max_event_interval_us.load(Ordering::Relaxed) as f64 / 1_000.0,
        metrics.safe_floor_packets.load(Ordering::Relaxed),
        metrics.expected_packet_bytes.load(Ordering::Relaxed),
    );
    result?;
    Ok(())
}

fn print_help() {
    println!(
        "RoaringMic Windows candidate\n\
         --probe                   Query endpoint capabilities only\n\
         --silent-render-probe     Render silence through WASAPI (no UDP input)\n\
         --udp --silent            Receive UDP and render silence (safe parallel mode)\n\
         --render                  Explicitly allow microphone audio to reach the device\n\
         --listen=ADDR             UDP bind address (default {DEFAULT_LISTEN})\n\
         --peer=IP                 Allowed sender IP (default {DEFAULT_PEER})\n\
         --device=TEXT             Render endpoint name match (default {DEFAULT_DEVICE_NEEDLE})\n\
         --period=FRAMES           Shared engine period (default {DEFAULT_PERIOD_FRAMES})\n\
         --prebuffer=N             Startup safety floor in packets (default {DEFAULT_PREBUFFER_PACKETS})\n\
         --seconds=N               Test duration; 0 runs until stopped (default 30)\n\
         --gain=N                  Gain 0..200 percent (default 100)"
    );
}

pub fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        print_help();
        return Ok(());
    }

    let _com = ComApartment::initialize()?;
    let needle =
        std::env::var("ROARING_MIC_DEVICE").unwrap_or_else(|_| DEFAULT_DEVICE_NEEDLE.to_owned());
    if args.iter().any(|arg| arg == "--probe") {
        return probe_device(&needle);
    }
    if let Some(index) = args.iter().position(|arg| arg == "--silent-render-probe") {
        let tail = &args[index + 1..];
        let seconds = tail
            .iter()
            .find_map(|arg| arg.strip_prefix("--seconds=")?.parse().ok())
            .unwrap_or(10);
        let period = tail
            .iter()
            .find_map(|arg| arg.strip_prefix("--period=")?.parse().ok());
        return silent_render_probe(&needle, seconds, period);
    }
    if args.iter().any(|arg| arg == "--udp") {
        return run_udp(Config::parse(&args)?);
    }

    Err(
        "select --probe, --silent-render-probe, or --udp (silent unless --render is supplied)"
            .into(),
    )
}
