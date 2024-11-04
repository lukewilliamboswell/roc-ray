use matchbox_socket::PeerId;

// TODO dead code until networking is implemented for Web
#[allow(dead_code)]
#[derive(Debug)]
pub enum MainToWorkerMsg {
    Shutdown,
    SendMessage(PeerId, Vec<u8>),
}

// TODO dead code until networking is implemented for Web
#[allow(dead_code)]
#[derive(Debug)]
pub enum WorkerToMainMsg {
    PeerConnected(PeerId),
    PeerDisconnected(PeerId),
    MessageReceived(PeerId, Vec<u8>),
    ConnectionFailed,
    Disconnected,
}

#[cfg(not(target_arch = "wasm32"))]
mod platform {
    use super::*;

    use matchbox_socket::{ChannelError, PeerState, WebRtcSocket};
    use std::cell::RefCell;
    use std::time::Duration;
    use tokio::sync::mpsc::{error::TrySendError, Receiver, Sender};

    thread_local! {
        static MAIN_TX: RefCell<Option<Sender<MainToWorkerMsg>>> = const {RefCell::new(None)};
        static MAIN_RX: RefCell<Option<Receiver<WorkerToMainMsg>>> = const {RefCell::new(None)};
    }

    /// send a message to the worker thread if it has been initialized
    /// will panic if the worker thread has disconnected or the
    /// MainToWorkerMsg buffer is full
    pub fn send_message(msg: MainToWorkerMsg) {
        MAIN_TX.with(|main_tx_cell| {
            if let Some(tx) = main_tx_cell.borrow().as_ref() {
                match tx.try_send(msg) {
                    Ok(_) => {}
                    Err(TrySendError::Closed(..)) => {
                        // if we panic here, the main thread will crash instead of cleanly shutting down
                        eprintln!("Worker thread has disconnected")
                    }
                    Err(TrySendError::Full(..)) => {
                        // if we panic here, the main thread will crash instead of cleanly shutting down
                        eprintln!("Ran out of space consider increasing MAIN_TO_WORKER_BUFFER_SIZE if required.")
                    }
                }
            } else {
                // sender not initialized, do nothing
            }
        })
    }

    // we allocate to a Vec here because these will be passed to roc
    // which will be responsible for freeing the memory
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

    pub fn init(
        rt: &tokio::runtime::Runtime,
        room_url: Option<String>,
    ) -> Option<tokio::task::JoinHandle<()>> {
        if let Some(room_url) = room_url {
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

            Some(rt.spawn(worker_loop(room_url, worker_rx, worker_tx)))
        } else {
            None
        }
    }

    async fn worker_loop(
        room_url: String,
        mut receiver: Receiver<MainToWorkerMsg>,
        sender: Sender<WorkerToMainMsg>,
    ) {
        let (mut socket, mut loop_fut) = WebRtcSocket::builder(room_url)
            .reconnect_attempts(Some(3))
            .add_reliable_channel()
            .build();

        let mut socket_update_interval =
            tokio::time::interval(Duration::from_millis(SOCKET_UPDATE_INTERVAL_MS));

        loop {
            tokio::select! {
                msg = receiver.recv() => {
                    use MainToWorkerMsg::*;
                    match msg {
                        Some(SendMessage(peer, bytes)) => {
                            socket.send(bytes.into_boxed_slice(), peer);
                        }
                        Some(Shutdown) => {
                            // Worker thread shutting down...
                            break;
                        }
                        None => {
                            // channel has been closed and there are no remaining messages in the channel's buffer
                            break;
                        }
                    }
                }

                _ = socket_update_interval.tick() => {
                    match process_webrtc_updates(&mut socket, &sender).await {
                        Ok(_) => {}
                        Err(TrySendError::Closed(..)) => panic!("Main thread has disconnected"),
                        Err(TrySendError::Full(..)) => panic!(
                            "Ran out of space consider increasing WORKER_TO_MAIN_BUFFER_SIZE if required."
                        ),
                    }
                }

                msg = &mut loop_fut => {
                    match msg {
                        Ok(()) => {
                            // WebRTC connection closed cleanly
                            break;
                        },
                        Err(matchbox_socket::Error::ConnectionFailed(..)) => {
                            sender.send(WorkerToMainMsg::ConnectionFailed).await.unwrap();
                            break;
                        }
                        Err(matchbox_socket::Error::Disconnected(..)) => {
                            sender.send(WorkerToMainMsg::Disconnected).await.unwrap();
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
    ) -> Result<(), TrySendError<WorkerToMainMsg>> {
        // Process any new peers connecting/disconnecting
        match socket.try_update_peers() {
            Ok(peers) => {
                for (peer_id, state) in peers {
                    match state {
                        PeerState::Connected => {
                            sender.try_send(WorkerToMainMsg::PeerConnected(peer_id))?;
                        }
                        PeerState::Disconnected => {
                            sender.try_send(WorkerToMainMsg::PeerDisconnected(peer_id))?;
                        }
                    }
                }
            }
            // refer to https://docs.rs/matchbox_socket/latest/matchbox_socket/enum.ChannelError.html
            // for more information on channel errors
            Err(ChannelError::Closed) => {
                panic!("WebRTC channel closed, maybe the room url was invalid")
            }
            Err(ChannelError::NotFound) => panic!("WebRTC channel not found"),
            Err(ChannelError::Taken) => {
                panic!("WebRTC channel taken, it is no longer on the socket")
            }
        }

        // process queued messages from peers
        for (peer_id, packet) in socket.receive() {
            sender.try_send(WorkerToMainMsg::MessageReceived(peer_id, packet.into_vec()))?;
        }

        Ok(())
    }
}

#[cfg(target_arch = "wasm32")]
mod platform {
    use super::*;

    pub fn get_messages() -> Vec<WorkerToMainMsg> {
        // TODO
        Vec::new()
    }
    pub fn send_message(_msg: MainToWorkerMsg) {
        // TODO
    }
}

pub use platform::*;
