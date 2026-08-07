# Vendored msf_gif (animated GIF encoder)

Source: msf_gif v2.4, https://github.com/notnullnotvoid/msf_gif
License: MIT or public domain (dual, see the end of `msf_gif.h`).

`msf_gif.h` is the upstream single-header library, vendored verbatim apart from
the local modification described below. `msf_gif_impl.c` is ours: it is the one
translation unit that defines `MSF_GIF_IMPL`, and it wraps the encoder in a
primitive-only shim so the Zig host never has to mirror `MsfGifState`. `shim/`
holds the four minimal libc headers the encoder includes, because the host is
built freestanding and the Windows cross-compile has no MSVC SDK; the actual
`malloc`/`memcpy` symbols resolve at final link, as raylib's already do.

## Local modification: recycle the compression buffer in the to-file path

Upstream's `msf_compress_frame` allocates a worst-case buffer
(`offsetof(MsfGifBuffer, data) + 32 + 768 + width * height * 3 / 2 + 260`, so
about 1.5 bytes per pixel) for every frame, shrinks it with a realloc, and the
to-file path then frees it one frame later. A 150-frame recording therefore did
150 mallocs, 150 reallocs and 150 frees of a multi-megabyte block that is the
same size every time.

The modification adds a single-slot buffer pool used only by the to-file API,
and is marked in place with `ROCRAY LOCAL MODIFICATION` comments. It is six
edits:

1. `MsfGifBuffer` gains `size_t allocSize`, the bytes actually allocated for the
   node. `size` no longer implies it, because a recycled node is not shrunk, and
   `MSF_GIF_FREE`/`MSF_GIF_REALLOC` are documented to receive the true old size.
2. `MsfGifState` gains `MsfGifBuffer * recycled`, cleared at the top of
   `msf_gif_begin` and freed in `msf_free_gif_state`.
3. `msf_compress_frame` takes the recycled node when it is large enough instead
   of allocating, and releases it if it is too small (only the 32-byte file
   header node can be).
4. `msf_compress_frame` skips the shrink-realloc in file mode. This is what
   makes recycling possible at all: a shrunk buffer can never be reused. The
   to-memory API holds every buffer until the end and so still shrinks exactly
   as upstream does.
5. `msf_gif_frame_to_file` parks the buffer it has just written in the recycled
   slot instead of freeing it.
6. `msf_gif_begin` fills in the header node's `next`/`size`/`allocSize` before
   its allocation-failure check, and that check now also tests `tlbMem` and
   `usedMem`. This is an upstream bug rather than fallout from the recycling:
   if any allocation there failed while the header node succeeded,
   `msf_free_gif_state` walked an uninitialized `next` pointer, and a failed
   `tlbMem`/`usedMem` was never noticed at all so `msf_cook_frame` would write
   through a null pointer. Confirmed against the unmodified upstream header
   with an allocator that poisons and an injected allocation failure.

One caveat: "file mode" is detected as `handle->fileWriteFunc != NULL`, and
upstream's `msf_gif_begin` never clears that field. A caller that used the
to-file API and then re-used the same handle with the plain to-memory API would
keep the unshrunk buffers and use far more memory than upstream. Nothing in
roc-ray does that -- `msf_gif_impl.c` drives one static handle through the
to-file API only -- but a future caller should not assume otherwise.

The file path holds at most two compression buffers at once -- the frame just
compressed is queued while the previous one is written out -- so one slot is
enough to make every frame after the second allocation-free.

Measured on a 150-frame 490x320 recording, replaying the real captured frames:
allocations fall from 157 mallocs + 150 reallocs + 157 frees to 9 + 0 + 9
regardless of frame count, total requested bytes from 38.9 MB to 4.0 MB, and
encode time by 4-7%. Output is byte-identical to upstream at every quality.
Peak live bytes rise about 5%, because file mode now holds two full-size
buffers rather than one full and one shrunk.

To re-vendor: drop in the new `msf_gif.h`, then re-apply the six edits above
by searching the old file for `ROCRAY LOCAL MODIFICATION`. If upstream has since
made the to-file path stop round-tripping through the buffer list, drop the
modification entirely rather than porting it.
