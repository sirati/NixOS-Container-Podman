use std::os::unix::process::ExitStatusExt;
use std::process::{Child, Command, ExitStatus};
use std::time::{Duration, Instant};
use std::{fs, thread};

fn launch(script: &str) -> Child {
    Command::new(env!("CARGO_BIN_EXE_prison-start"))
        .args(["sh", "-c", script])
        .spawn()
        .unwrap()
}

fn wait(child: &mut Child) -> ExitStatus {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        assert!(Instant::now() < deadline, "prison-start did not exit");
        thread::sleep(Duration::from_millis(20));
    }
}

fn marker(name: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("prison-start-{}-{name}", std::process::id()));
    let _ = fs::remove_file(&path);
    path
}

fn wait_for(path: &std::path::Path) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !path.exists() {
        assert!(Instant::now() < deadline, "child never started");
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn success_and_failure_pass_through() {
    assert_eq!(wait(&mut launch("exit 0")).code(), Some(0));
    assert_eq!(wait(&mut launch("exit 1")).code(), Some(1));
    assert_eq!(wait(&mut launch("exit 125")).code(), Some(125));
    assert_eq!(wait(&mut launch("kill -KILL $$")).signal(), Some(9));
}

// The child keeps failing with 1 after the stop, as podman run does.
#[test]
fn a_failure_after_its_own_stop_is_a_stop() {
    let started = marker("stop");
    let mut child = launch(&format!(
        "trap 'exit 1' TERM; touch {}; while :; do sleep 0.05; done",
        started.display()
    ));
    wait_for(&started);
    unsafe {
        assert_eq!(libc_kill(child.id() as i32, 15), 0);
    }
    // systemd signals the child too, after the control process.
    let _ = Command::new("pkill").args(["-TERM", "-P", &child.id().to_string()]).status();
    let status = wait(&mut child);
    assert_eq!(status.signal(), Some(15), "{status}");
    let _ = fs::remove_file(started);
}

// A failure nobody asked for stays a failure, even if the child was signalled.
#[test]
fn a_failure_without_a_stop_is_a_failure() {
    let started = marker("nostop");
    let mut child = launch(&format!(
        "trap 'exit 1' TERM; touch {}; while :; do sleep 0.05; done",
        started.display()
    ));
    wait_for(&started);
    let _ = Command::new("pkill").args(["-TERM", "-P", &child.id().to_string()]).status();
    let status = wait(&mut child);
    assert_eq!(status.code(), Some(1), "{status}");
    let _ = fs::remove_file(started);
}

extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}
