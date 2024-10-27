use matchbox_socket::{Error as SocketError, PeerId, PeerState, WebRtcSocket};
use std::cell::RefCell;
use std::time::Duration;
use tokio::sync::mpsc::{error::SendError, Receiver, Sender};
use tokio::time::interval;

thread_local! {
    static MAIN_TX: RefCell<Option<Sender<MainToWorkerMsg>>> = RefCell::new(None);
    static MAIN_RX: RefCell<Option<Receiver<WorkerToMainMsg>>> = RefCell::new(None);
}

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

pub fn send_message(msg: MainToWorkerMsg) {
    MAIN_TX.with(|main_tx_cell| {
        if let Some(tx) = main_tx_cell.borrow().as_ref() {
            if let Err(..) = tx.try_send(msg) {
                eprintln!("Main thread has disconnected");
            }
        } else {
            eprintln!("Main sender not initialized");
        }
    })
}

pub fn get_messages() -> Vec<WorkerToMainMsg> {
    let mut messages = Vec::with_capacity(100);
    MAIN_RX.with(|main_rx_cell| {
        if let Some(rx) = main_rx_cell.borrow_mut().as_mut() {
            while let Ok(msg) = rx.try_recv() {
                messages.push(msg);
            }
        }
    });
    messages
}

const MAIN_TO_WORKER_BUFFER_SIZE: usize = 100;
const WORKER_TO_MAIN_BUFFER_SIZE: usize = 1000;
const SOCKET_UPDATE_INTERVAL_MS: u64 = 50;

pub fn init(rt: &tokio::runtime::Runtime) -> tokio::task::JoinHandle<()> {
    let (main_tx, worker_rx) =
        tokio::sync::mpsc::channel::<MainToWorkerMsg>(MAIN_TO_WORKER_BUFFER_SIZE);
    let (worker_tx, main_rx) =
        tokio::sync::mpsc::channel::<WorkerToMainMsg>(WORKER_TO_MAIN_BUFFER_SIZE);

    MAIN_TX.with(|main_tx_cell| {
        *main_tx_cell.borrow_mut() = Some(main_tx);
    });

    MAIN_RX.with(|main_rx_cell| {
        *main_rx_cell.borrow_mut() = Some(main_rx);
    });

    rt.spawn(worker_loop(worker_rx, worker_tx))
}

async fn worker_loop(mut receiver: Receiver<MainToWorkerMsg>, sender: Sender<WorkerToMainMsg>) {
    // TODO let's not hardcode this... WIP
    let room_url = "ws://localhost:3536/yolo?next?2";

    eprintln!("Worker connecting to WebRTC {room_url}");

    let (mut socket, mut loop_fut) = WebRtcSocket::builder(room_url)
        .reconnect_attempts(Some(3))
        .add_reliable_channel()
        .build();

    let mut socket_interval = interval(Duration::from_millis(SOCKET_UPDATE_INTERVAL_MS));

    loop {
        tokio::select! {
            msg = receiver.recv() => {
                use MainToWorkerMsg::*;
                match msg {
                    Some(Shutdown) => {
                        eprintln!("Worker received shutdown message, exiting...");
                        break;
                    }
                    Some(Tick) => {
                        // TODO these try_send have two failure modes,
                        // 1. the channel is closed, in which case we should break
                        // 2. the channel is full, in which case we should log it??
                        if let Err(..) = sender.try_send(WorkerToMainMsg::Tock) {
                            eprintln!("Main thread has disconnected");
                            break;
                        }
                    }
                    Some(SendMessage(peer, bytes)) => {
                        socket.send(bytes.into_boxed_slice(), peer);
                    }
                    None => {
                        eprintln!("Channel closed");
                        break;
                    }
                }
            }

            _ = socket_interval.tick() => {
                match process_webrtc_updates(&mut socket, &sender).await {
                    Ok(()) => (),
                    Err(e) => {
                        eprintln!("WebRTC error: {}", e);
                        if let Err(..) = sender.try_send(WorkerToMainMsg::Error(e.to_string())) {
                            eprintln!("Failed to send error to main thread");
                            break;
                        }
                    }
                }
            }

            msg = &mut loop_fut => {
                match msg {
                    Ok(()) => {
                        eprintln!("WebRTC connection closed cleanly");
                        break;
                    },
                    Err(SocketError::ConnectionFailed(e)) => {
                        eprintln!("WebRTC connection failed: {}", e);
                        break;
                    }
                    Err(SocketError::Disconnected(e)) => {
                        eprintln!("WebRTC connection disconnected: {}", e);
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
        Err(_channel_err) => {
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
