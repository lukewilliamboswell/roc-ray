use matchbox_socket::{PeerState, WebRtcSocket};
use std::sync::mpsc::{Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant};
use tokio::runtime::Runtime;

#[derive(Debug)]
pub enum MainToWorkerMsg {
    Tick,
    Shutdown,
}

#[derive(Debug)]
pub enum WorkerToMainMsg {
    Tock,
    PeerConnected(matchbox_socket::PeerId),
    PeerDisconnected(matchbox_socket::PeerId),
    MessageReceived(matchbox_socket::PeerId, Vec<u8>),
}

pub fn worker_loop(receiver: Receiver<MainToWorkerMsg>, sender: Sender<WorkerToMainMsg>) {
    println!("Worker thread started");

    println!("Worker connecting to WebRTC server...");
    // Create a minimal runtime
    let rt = Runtime::new().expect("Failed to create runtime");

    println!("Worker connecting to WebRTC server...");
    let (mut socket, loop_fut) = WebRtcSocket::new_reliable("ws://localhost:3536/");

    // Spawn the message loop future
    let message_loop_handle = rt.spawn(loop_fut);

    let mut last_socket_update = Instant::now();
    let socket_update_interval = Duration::from_millis(100);

    'worker: loop {
        // Check if the message loop is still running
        if message_loop_handle.is_finished() {
            println!("WebRTC message loop has ended");
            break 'worker;
        }

        // Process messages from main thread without blocking
        while let Ok(msg) = receiver.try_recv() {
            match msg {
                MainToWorkerMsg::Shutdown => {
                    println!("Worker received shutdown message, exiting...");
                    break 'worker;
                }
                MainToWorkerMsg::Tick => {
                    if sender.send(WorkerToMainMsg::Tock).is_err() {
                        println!("Main thread has disconnected");
                        break 'worker;
                    }
                }
            }
        }

        // Process WebRTC
        let now = Instant::now();
        if now.duration_since(last_socket_update) >= socket_update_interval {
            // Update peers
            for (peer, state) in socket.update_peers() {
                match state {
                    PeerState::Connected => {
                        println!("Peer joined: {peer}");
                        sender
                            .send(WorkerToMainMsg::PeerConnected(peer))
                            .unwrap_or_else(|e| println!("Failed to send peer connected: {e}"));

                        // Example: send welcome message
                        let packet = "hello friend!".as_bytes().to_vec().into_boxed_slice();
                        socket.send(packet, peer);
                    }
                    PeerState::Disconnected => {
                        println!("Peer left: {peer}");
                        sender
                            .send(WorkerToMainMsg::PeerDisconnected(peer))
                            .unwrap_or_else(|e| println!("Failed to send peer disconnected: {e}"));
                    }
                }
            }

            // Receive messages
            for (peer, packet) in socket.receive() {
                sender
                    .send(WorkerToMainMsg::MessageReceived(peer, packet.to_vec()))
                    .unwrap_or_else(|e| println!("Failed to send message received: {e}"));
            }

            last_socket_update = now;
        }

        // Small sleep to prevent busy-waiting
        thread::sleep(Duration::from_millis(1));
    }

    message_loop_handle.abort();

    rt.shutdown_background();

    println!("Worker thread shutting down");
}
