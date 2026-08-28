## Private decoding of the flat records the host reports each cycle.
## This module is intentionally absent from the package exposes list.
import HostABI
import Capture

AppTransport := [].{

	## Turn the host's flat recording record into the public union.
	capture_status : HostABI.AppRawCaptureStatus -> Capture.Status
	capture_status = |raw|
		if raw.status == capture_status_active {
			Active({ frames: raw.frames, dropped: raw.dropped })
		}
			else if raw.status == capture_status_failed {
				Failed({ frames: raw.frames, reason: capture_failure(raw.err) })
			}
				else if raw.status == capture_status_finished {
					Finished({ frames: raw.frames, bytes: raw.bytes })
				}
					else {
						Idle
					}
}

## `status` code for a running recording. Mirrored in `src/capture.zig`.
capture_status_active : U8
capture_status_active = 1

## `status` code for a recording that stopped early. Mirrored in `src/capture.zig`.
capture_status_failed : U8
capture_status_failed = 2

## `status` code for a recording that ran to its end and wrote its file.
## Mirrored in `src/capture.zig`.
capture_status_finished : U8
capture_status_finished = 3

## Name every failure code a recording can latch -- a start the host refused as
## well as a running recording that stopped early.
capture_failure : U8 -> Capture.FailureReason
capture_failure = |code|
	match code {
		1 => PathInvalid
		2 => PathEscapesOutputDir
		3 => AlreadyRecording
		5 => UnsupportedFormat
		6 => BudgetExceeded
		7 => OutOfMemory
		8 => WriteFailed
		9 => EncodeFailed
		_ => Unknown
	}

expect capture_failure(2) == PathEscapesOutputDir
expect capture_failure(9) == EncodeFailed
expect capture_failure(99) == Unknown

expect AppTransport.capture_status({ status: 0, err: 0, frames: 0, dropped: 0, bytes: 0 }) == Idle
expect AppTransport.capture_status({ status: 1, err: 0, frames: 12, dropped: 3, bytes: 0 })
	== Active({ frames: 12, dropped: 3 })
expect AppTransport.capture_status({ status: 2, err: 8, frames: 4, dropped: 0, bytes: 0 })
	== Failed({ frames: 4, reason: WriteFailed })
expect AppTransport.capture_status({ status: 3, err: 0, frames: 90, dropped: 1, bytes: 4096 })
	== Finished({ frames: 90, bytes: 4096 })
