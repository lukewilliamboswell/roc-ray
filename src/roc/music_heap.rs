use std::cell::RefCell;
use std::sync::OnceLock;

use roc_std::RocBox;
use roc_std_heap::ThreadSafeRefcountedResourceHeap;

use crate::bindings;

thread_local! {
    static MUSIC_STREAMS: RefCell<Vec<RocBox<()>>> = const { RefCell::new(vec![]) };
}

pub fn alloc_music_stream(music: bindings::Music) -> Result<RocBox<()>, ()> {
    let heap = music_heap();

    let alloc_result = heap.alloc_for(music);
    match alloc_result {
        Ok(mut roc_box) => {
            MUSIC_STREAMS.with_borrow_mut(|streams| {
                streams.push(roc_box.clone());
            });

            // don't count our clone as a reference; we clean ours in dealloc
            use roc_std::RocRefcounted;
            roc_box.dec();

            Ok(roc_box)
        }
        Err(_) => Err(()),
    }
}

pub fn update_music_streams() {
    MUSIC_STREAMS.with_borrow_mut(|streams| {
        for music_box in streams.iter().cloned() {
            let music: &mut bindings::Music =
                ThreadSafeRefcountedResourceHeap::box_to_resource(music_box);

            unsafe {
                bindings::UpdateMusicStream(*music);
            }
        }
    })
}

// note this is checked and deallocated in the roc_dealloc function
pub(super) fn music_heap() -> &'static ThreadSafeRefcountedResourceHeap<bindings::Music> {
    static MUSIC_HEAP: OnceLock<ThreadSafeRefcountedResourceHeap<bindings::Music>> =
        OnceLock::new();
    const DEFAULT_ROC_RAY_MAX_MUSIC_STREAMS_HEAP_SIZE: usize = 1000;
    let max_heap_size = std::env::var("ROC_RAY_MAX_MUSIC_HEAPS_HEAP_SIZE")
        .map(|v| {
            v.parse()
                .unwrap_or(DEFAULT_ROC_RAY_MAX_MUSIC_STREAMS_HEAP_SIZE)
        })
        .unwrap_or(DEFAULT_ROC_RAY_MAX_MUSIC_STREAMS_HEAP_SIZE);
    MUSIC_HEAP.get_or_init(|| {
        ThreadSafeRefcountedResourceHeap::new(max_heap_size)
            .expect("Failed to allocate mmap for heap references.")
    })
}
