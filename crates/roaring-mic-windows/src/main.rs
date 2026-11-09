#![cfg_attr(not(windows), allow(dead_code))]

#[cfg(windows)]
mod windows_engine;

#[cfg(windows)]
fn main() {
    if let Err(error) = windows_engine::run() {
        eprintln!("RoaringMic WASAPI candidate failed: {error}");
        std::process::exit(1);
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!(
        "roaring-mic-windows is a Windows-only audio receiver; run its checks on a Windows target."
    );
}
