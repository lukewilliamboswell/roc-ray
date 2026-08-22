## Private request/response transport shared by the Roc adapter and native host.
##
## This module is intentionally absent from the platform's `exposes` list.
## Applications use `App.Request` and receive mapped messages through
## `App.Input`; raw records and correlation tickets stay below that boundary.
import Files
import Capture
import Window

AppHost := [].{

	## The public `App.Request(msg)`. Declared here so `AppTransport` can name
	## it without importing `App`, which imports `AppTransport`.
	Request(msg) : [
		ReadText({ path : Str, callback : Try(Str, Files.ReadTextError) -> msg }),
		ReadBytes({ path : Str, callback : Try(List(U8), Files.ReadBytesError) -> msg }),
		Delay({ millis : U64, callback : Try({}, [Busy]) -> msg }),
		Screenshot({ path : Str, callback : Try({}, Capture.ScreenshotError) -> msg }),
		ReadClipboard({ callback : Try(Str, Window.ClipboardReadError) -> msg }),
		ListDirectory({ path : Str, callback : Try(List(Files.Entry), Files.ListError) -> msg }),
	]

	## Hand one normalized request to the host. It answers on a later input
	## through `PendingResponse`.
	submit_request! : SubmittedRequest(msg) => {}

	SubmittedRequest(msg) : {
		kind : U8,
		path : Str,
		millis : U64,
		deliver : Box(RawResponse -> Box(msg)),
	}

	RawResponse : {
		kind : U8,
		ticket : U64,
		err : U8,
		contents : Str,
		bytes : List(U8),
	}

	PendingResponse(msg) : {
		raw : RawResponse,
		deliver : Box(RawResponse -> Box(msg)),
	}

	RawCaptureStatus : {
		status : U8,
		err : U8,
		frames : U64,
		dropped : U64,
		bytes : U64,
	}
}
