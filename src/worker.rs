use matchbox_socket::{PeerId, PeerState, WebRtcSocket};
use std::time::Duration;
use tokio::sync::mpsc::{Receiver, Sender};
use tokio::time::interval;

#[derive(Debug)]
pub enum MainToWorkerMsg {
    Tick,
    Shutdown,
}

#[derive(Debug)]
pub enum WorkerToMainMsg {
    Tock,
    PeerConnected(PeerId),
    PeerDisconnected(PeerId),
    MessageReceived(PeerId, Vec<u8>),
    Error(String),
}

// Custom error type that implements Send
#[derive(Debug)]
struct WorkerError(String);

impl std::error::Error for WorkerError {}

impl std::fmt::Display for WorkerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

pub async fn worker_loop(mut receiver: Receiver<MainToWorkerMsg>, sender: Sender<WorkerToMainMsg>) {
    println!("Worker task started");

    println!("Worker connecting to WebRTC server...");
    let (mut socket, loop_fut) = WebRtcSocket::new_reliable("ws://localhost:3536/");

    // Spawn the message loop future on the current runtime
    let message_loop_handle = tokio::spawn(loop_fut);

    let mut socket_interval = interval(Duration::from_millis(100));

    loop {
        tokio::select! {
            msg = receiver.recv() => {
                match msg {
                    Some(MainToWorkerMsg::Shutdown) => {
                        println!("Worker received shutdown message, exiting...");
                        break;
                    }
                    Some(MainToWorkerMsg::Tick) => {
                        if sender.send(WorkerToMainMsg::Tock).await.is_err() {
                            println!("Main thread has disconnected");
                            break;
                        }
                    }
                    None => {
                        println!("Channel closed");
                        break;
                    }
                }
            }

            _ = socket_interval.tick() => {
                // Process WebRTC updates
                if let Err(e) = process_webrtc_updates(&mut socket, &sender).await {
                    println!("WebRTC error: {}", e);
                    // Try to notify main thread of the error
                    let _ = sender.send(WorkerToMainMsg::Error(e.to_string())).await;
                    break;
                }
            }
        }
    }

    // Clean up
    message_loop_handle.abort();

    if let Err(e) = message_loop_handle.await {
        println!("Error waiting for message loop to end: {e}");
        let _ = sender.send(WorkerToMainMsg::Error(e.to_string())).await;
    }

    println!("Worker task shutting down");
}

async fn process_webrtc_updates(
    socket: &mut WebRtcSocket,
    sender: &Sender<WorkerToMainMsg>,
) -> Result<(), WorkerError> {
    // Process peer updates
    for (peer, state) in socket.update_peers() {
        match state {
            PeerState::Connected => {
                println!("Peer joined: {peer}");
                sender
                    .send(WorkerToMainMsg::PeerConnected(peer))
                    .await
                    .map_err(|e| WorkerError(format!("Failed to send peer connected: {}", e)))?;

                let packet = "hello friend!".as_bytes().to_vec().into_boxed_slice();
                socket.send(packet, peer);
            }
            PeerState::Disconnected => {
                println!("Peer left: {peer}");
                sender
                    .send(WorkerToMainMsg::PeerDisconnected(peer))
                    .await
                    .map_err(|e| WorkerError(format!("Failed to send peer disconnected: {}", e)))?;
            }
        }
    }

    // Receive messages
    for (peer, packet) in socket.receive() {
        sender
            .send(WorkerToMainMsg::MessageReceived(peer, packet.to_vec()))
            .await
            .map_err(|e| WorkerError(format!("Failed to send message received: {}", e)))?;
    }

    Ok(())
}
