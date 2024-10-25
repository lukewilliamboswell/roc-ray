use matchbox_socket::{Error as SocketError, PeerId, PeerState, WebRtcSocket};
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
    ConnectionStatus(ConnectionState),
}

#[derive(Debug)]
pub enum ConnectionState {
    Connected,
    Disconnected(String),
    Failed(String),
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
    println!("Worker connecting to WebRTC server...");
    let (mut socket, mut loop_fut) = WebRtcSocket::new_reliable("ws://localhost:3536/");

    let mut socket_interval = interval(Duration::from_millis(100));
    let mut connection_established = false;

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
                match process_webrtc_updates(&mut socket, &sender).await {
                    Ok(_) => {
                        if !connection_established {
                            connection_established = true;
                            let _ = sender.send(WorkerToMainMsg::ConnectionStatus(ConnectionState::Connected)).await;
                        }
                    }
                    Err(e) => {
                        println!("WebRTC error: {}", e);
                        let _ = sender.send(WorkerToMainMsg::Error(e.to_string())).await;
                        // Don't break here - let the loop_fut handle decide if we need to exit
                    }
                }
            }

            msg = &mut loop_fut => {
                match msg {
                    Ok(()) => {
                        println!("WebRTC connection closed cleanly");
                        let _ = sender.send(WorkerToMainMsg::ConnectionStatus(
                            ConnectionState::Disconnected("Connection closed".to_string())
                        )).await;

                        break;
                    },
                    Err(e) => {let status = match e {
                            SocketError::ConnectionFailed(e) => {
                                ConnectionState::Failed(format!(
                                    "Failed to connect to signaling server: {}", e
                                ))
                            }
                            SocketError::Disconnected(e) => {
                                ConnectionState::Disconnected(format!(
                                    "Connection lost: {}", e
                                ))
                            }
                        };

                        let _ = sender.send(WorkerToMainMsg::ConnectionStatus(status)).await;
                        break;
                    },
                }
            }
        }
    }
}

async fn process_webrtc_updates(
    socket: &mut WebRtcSocket,
    sender: &Sender<WorkerToMainMsg>,
) -> Result<(), WorkerError> {
    // Process peer updates
    if let Ok(peers) = socket.try_update_peers() {
        // dbg!(&peers);
        for (peer, state) in peers {
            match state {
                PeerState::Connected => {
                    println!("Peer joined: {peer}");
                    sender
                        .send(WorkerToMainMsg::PeerConnected(peer))
                        .await
                        .map_err(|e| {
                            WorkerError(format!("Failed to send peer connected: {}", e))
                        })?;

                    let packet = "hello friend!".as_bytes().to_vec().into_boxed_slice();
                    socket.send(packet, peer);
                }
                PeerState::Disconnected => {
                    println!("Peer left: {peer}");
                    sender
                        .send(WorkerToMainMsg::PeerDisconnected(peer))
                        .await
                        .map_err(|e| {
                            WorkerError(format!("Failed to send peer disconnected: {}", e))
                        })?;
                }
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
