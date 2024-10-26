use matchbox_socket::{Error as SocketError, PeerId, PeerState, WebRtcSocket};
use std::time::Duration;
use tokio::sync::mpsc::{error::SendError, Receiver, Sender};
use tokio::time::interval;

#[derive(Debug)]
pub enum MainToWorkerMsg {
    Tick,
    Shutdown,
    SendMessage(PeerId, Vec<u8>),
}

#[derive(Debug)]
pub enum WorkerToMainMsg {
    Tock,
    PeerConnected(PeerId),
    PeerDisconnected(PeerId),
    MessageReceived(PeerId, Vec<u8>),
    Error(String),
    // ConnectionStatus(ConnectionState),
}

// #[derive(Debug)]
// pub enum ConnectionState {
//     Connected,
//     Disconnected(String),
//     Failed(String),
// }

// Custom error type that implements Send
// #[derive(Debug)]
// struct WorkerError(String);

// impl std::error::Error for WorkerError {}

// impl std::fmt::Display for WorkerError {
//     fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
//         write!(f, "{}", self.0)
//     }
// }

pub async fn worker_loop(mut receiver: Receiver<MainToWorkerMsg>, sender: Sender<WorkerToMainMsg>) {
    let start = std::time::SystemTime::now();

    let room_url = "ws://localhost:3536/yolo?next?2";

    println!("Worker connecting to WebRTC {room_url}");

    let (mut socket, mut loop_fut) = WebRtcSocket::builder(room_url)
        .reconnect_attempts(Some(3))
        .add_reliable_channel()
        .build();

    let mut socket_interval = interval(Duration::from_millis(500));

    loop {
        tokio::select! {
            msg = receiver.recv() => {
                use MainToWorkerMsg::*;
                match msg {
                    Some(Shutdown) => {
                        println!("Worker received shutdown message, exiting...");
                        break;
                    }
                    Some(Tick) => {
                        // TODO these try_send have two failure modes,
                        // 1. the channel is closed, in which case we should break
                        // 2. the channel is full, in which case we should log it??
                        if let Err(..) = sender.try_send(WorkerToMainMsg::Tock) {
                            println!("Main thread has disconnected");
                            break;
                        }
                    }
                    Some(SendMessage(peer, bytes)) => {
                        socket.send(bytes.into_boxed_slice(), peer);
                    }
                    None => {
                        println!("Channel closed");
                        break;
                    }
                }
            }

            _ = socket_interval.tick() => {
                println!("SOCKET INTERVAL TICK, {:?}", std::time::SystemTime::now().duration_since(start).unwrap().as_millis());
                dbg!(&socket.is_closed());
                dbg!(&socket.connected_peers().count());

                match process_webrtc_updates(&mut socket, &sender).await {
                    Ok(()) => (),
                    Err(e) => {
                        println!("WebRTC error: {}", e);
                        if let Err(..) = sender.try_send(WorkerToMainMsg::Error(e.to_string())) {
                            println!("Failed to send error to main thread");
                            break;
                        }
                    }
                }
            }

            msg = &mut loop_fut => {
                match msg {
                    Ok(()) => {
                        println!("WebRTC connection closed cleanly");
                        break;
                    },
                    Err(SocketError::ConnectionFailed(e)) => {
                        println!("WebRTC connection failed: {}", e);
                        break;
                    }
                    Err(SocketError::Disconnected(e)) => {
                        println!("WebRTC connection disconnected: {}", e);
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
) -> Result<(), SendError<WorkerToMainMsg>> {
    // Process any new peers connecting/disconnecting
    match socket.try_update_peers() {
        Ok(peers) => {
            for (peer_id, state) in peers {
                match state {
                    PeerState::Connected => {
                        sender.send(WorkerToMainMsg::PeerConnected(peer_id)).await?;
                    }
                    PeerState::Disconnected => {
                        sender
                            .send(WorkerToMainMsg::PeerDisconnected(peer_id))
                            .await?;
                    }
                }
            }
        }
        Err(channel_err) => {
            dbg!(&channel_err);
            // https://docs.rs/matchbox_socket/latest/matchbox_socket/enum.ChannelError.html
            todo!("Handle channel error here");
        }
    }

    // Receive queued messages
    for (peer_id, packet) in socket.receive() {
        sender
            .send(WorkerToMainMsg::MessageReceived(peer_id, packet.into_vec()))
            .await?;
    }

    Ok(())
}
