//! Windows WASAPI endpoint discovery and low-period render probe.
//!
//! The probe deliberately renders silence. It validates the exact IAudioClient3
//! shared-mode path and event cadence without injecting a second microphone
//! signal into CABLE Input. Production UDP rendering is a separate next step.

use std::error::Error;
use std::time::{Duration, Instant};

use wasapi::{
    initialize_mta, AudioClient, AudioClientProperties, Device, DeviceEnumerator, Direction,
    SampleType, StreamCategory, WasapiError,
};
use windows::core::{Interface, PCWSTR};
use windows::Win32::Foundation::HANDLE;
use windows::Win32::Media::Audio::{IAudioClient3, IAudioRenderClient};
use windows::Win32::System::Threading::{
    AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW, AvSetMmThreadPriority,
    AVRT_PRIORITY_HIGH,
};

const DEFAULT_DEVICE_NEEDLE: &str = "CABLE Input";
const STREAMFLAGS_EVENTCALLBACK: u32 = 0x0004_0000;
const BUFFERFLAGS_SILENT: u32 = 0x0000_0002;

struct MmcssRegistration(HANDLE);

impl MmcssRegistration {
    fn enter(task_name: &str) -> Option<Self> {
        let wide: Vec<u16> = task_name.encode_utf16().chain(Some(0)).collect();
        let mut task_index = 0_u32;
        let handle =
            unsafe { AvSetMmThreadCharacteristicsW(PCWSTR(wide.as_ptr()), &mut task_index) }
                .ok()?;
        let _ = unsafe { AvSetMmThreadPriority(handle, AVRT_PRIORITY_HIGH) };
        Some(Self(handle))
    }
}

impl Drop for MmcssRegistration {
    fn drop(&mut self) {
        let _ = unsafe { AvRevertMmThreadCharacteristics(self.0) };
    }
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
    initialize_mta().ok()?;
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
    let (device, client, mix) = open_target(needle)?;
    client.set_properties(AudioClientProperties::new().set_category(StreamCategory::Other))?;
    let periods = client.get_shared_mode_engine_period(&mix)?;
    let period_frames = requested_period.unwrap_or(periods.min);
    if period_frames < periods.min
        || period_frames > periods.max
        || !(period_frames - periods.min).is_multiple_of(periods.fundamental)
    {
        return Err(format!(
            "requested period {period_frames} is not supported; valid range {}..={} with fundamental {}",
            periods.min, periods.max, periods.fundamental
        )
        .into());
    }

    let rate = mix.get_samplespersec();
    if rate != 48_000 || mix.get_subformat()? != SampleType::Float || mix.get_bitspersample() != 32
    {
        return Err(format!(
            "candidate expects a 48 kHz 32-bit-float mix format; endpoint reports {} Hz, {} bit, {:?}",
            rate,
            mix.get_bitspersample(),
            mix.get_subformat()?
        )
        .into());
    }

    let client3: IAudioClient3 = client.as_iaudioclient().cast()?;
    unsafe {
        client3.InitializeSharedAudioStream(
            STREAMFLAGS_EVENTCALLBACK,
            period_frames,
            mix.as_waveformatex_ref(),
            None,
        )?;
    }

    let event_handle = client.set_get_eventhandle()?;
    let render: IAudioRenderClient = unsafe { client.as_iaudioclient().GetService()? };
    let buffer_frames = client.get_buffer_size()?;
    let block_align = mix.get_blockalign() as usize;
    if block_align == 0 || mix.get_nchannels() != 2 {
        return Err(format!(
            "unexpected endpoint block alignment/channel count: {block_align}/{}",
            mix.get_nchannels()
        )
        .into());
    }

    let _mmcss = MmcssRegistration::enter("Pro Audio");
    let initial_frames = client.get_available_space_in_frames()?;
    if initial_frames > 0 {
        let _ = unsafe { render.GetBuffer(initial_frames)? };
        unsafe { render.ReleaseBuffer(initial_frames, BUFFERFLAGS_SILENT)? };
    }
    client.start_stream()?;

    let mut intervals_ms = Vec::with_capacity(seconds as usize * 600);
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
                let available = client.get_available_space_in_frames()?;
                if available == 0 {
                    empty_writes += 1;
                } else {
                    let _ = unsafe { render.GetBuffer(available)? };
                    unsafe { render.ReleaseBuffer(available, BUFFERFLAGS_SILENT)? };
                }
            }
            Err(WasapiError::EventTimeout) => timeout_count += 1,
            Err(error) => return Err(Box::new(error)),
        }
    }

    client.stop_stream()?;
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
        f64::from(period_frames) * 1_000.0 / f64::from(rate),
        buffer_frames,
        f64::from(buffer_frames) * 1_000.0 / f64::from(rate)
    );
    println!("EVENTS={event_count} TIMEOUTS={timeout_count} EMPTY_WRITES={empty_writes}");
    println!(
        "EVENT_MS median={:.3} p95={:.3} p99={:.3} max={:.3}",
        percentile(0.50),
        percentile(0.95),
        percentile(0.99),
        intervals_ms.last().copied().unwrap_or(0.0)
    );
    println!("MMCSS_PRO_AUDIO={}", _mmcss.is_some());
    println!("AUDIO_PAYLOAD=silent; no microphone samples injected");
    Ok(())
}

pub fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let needle =
        std::env::var("ROARING_MIC_DEVICE").unwrap_or_else(|_| DEFAULT_DEVICE_NEEDLE.to_owned());

    if args.iter().any(|arg| arg == "--probe") {
        return probe_device(&needle);
    }
    if args.iter().any(|arg| arg == "--silent-render-probe") {
        let seconds = args
            .iter()
            .find_map(|arg| arg.strip_prefix("--seconds=")?.parse().ok())
            .unwrap_or(10);
        let period = args
            .iter()
            .find_map(|arg| arg.strip_prefix("--period=")?.parse().ok());
        return silent_render_probe(&needle, seconds, period);
    }

    Err("audio streaming is not enabled in this candidate yet; use --probe or --silent-render-probe".into())
}
