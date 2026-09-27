## What an app may reach beyond its own resources.
##
## Some things every app has without asking: its window, input, clocks,
## standard output and error, captures under its output directory, and the
## directory beside its executable. Everything else -- network origins and
## peers, other directories, programs, environment variables, the clipboard --
## is declared in the startup `Config`, and the declaration is the grant:
##
## ```roc
## config =
##     App.default
##     .with_title("Weather")
##     .with_permission(Permission.http_origin("https://api.example.com"))
##     .with_permission(Permission.env_var("WEATHER_TOKEN"))
## ```
##
## There is no launch flag that widens this, so what an app can reach is read
## from its source and changed only by changing its source.
##
## Declare each facility as narrowly as it allows. An origin, a port, a program
## name, or a variable name is a scope: an effect whose target falls outside
## every declared scope returns `PermissionDenied` without doing anything,
## because a URL or path can be runtime data. Using a facility the app never
## declared at all is a programmer error: the app stops at once with a message
## naming the effect and the declaration to add.
##
## Each facility also has one unscoped declaration -- `http_any`, `udp_any`,
## `command_any`, `env_any`, `files_anywhere` -- for tools that genuinely need
## it. They are spelled to stand out in review.
##
## A declaration is platform policy, not an operating-system sandbox: it bounds
## what Roc code in the app can reach, because that code has no way to reach
## anything except through the platform.
import Url

Permission :: {
	kind : U8,
	mode : U8,
	port : U16,
	text : Str,
}.{

	## Whether a declared directory may be written, or only read.
	Mode : [ReadOnly, ReadWrite]

	## Send HTTP requests to one origin: a scheme, a host, and a port.
	##
	## The origin is the URL's scheme, host, and port, with no path, query, or
	## credentials; a default port may be left out. `https://api.example.com`
	## permits `https://api.example.com/v1/forecast` but not
	## `http://api.example.com`, `https://api.example.com:8443`, or
	## `https://cdn.example.com`. A redirect to another origin is refused unless
	## that origin is declared too.
	http_origin : Url -> Permission
	http_origin = |url| declare(kind_http_origin, 0, 0, url.to_str())

	## Send HTTP requests anywhere. Prefer `http_origin` unless the app's
	## destinations truly are open-ended, such as a user-typed URL.
	http_any : Permission
	http_any = declare(kind_http_any, 0, 0, "")

	## Bind a UDP socket to one local port.
	udp_bind : U16 -> Permission
	udp_bind = |port| declare(kind_udp_bind, 0, port, "")

	## Send UDP datagrams to one IPv4 peer, written as a dotted quad such as
	## `"127.0.0.1"`. Declaring a peer also permits binding an ephemeral port
	## (port `0`) to talk to it.
	udp_peer : Str, U16 -> Permission
	udp_peer = |address, port| declare(kind_udp_peer, 0, port, address)

	## Bind any port and send to any peer.
	udp_any : Permission
	udp_any = declare(kind_udp_any, 0, 0, "")

	## Run one program, named exactly as the app names it to `Cmd`. Declaring
	## `"git"` permits running `"git"`, looked up on `PATH`; it does not permit
	## `"/usr/bin/git"` or anything else.
	command : Str -> Permission
	command = |program| declare(kind_command, 0, 0, program)

	## Run any program. A child process has all of the user's authority, so this
	## is the widest declaration there is.
	command_any : Permission
	command_any = declare(kind_command_any, 0, 0, "")

	## Read one environment variable by exact name.
	env_var : Str -> Permission
	env_var = |name| declare(kind_env_var, 0, 0, name)

	## Read any environment variable.
	env_any : Permission
	env_any = declare(kind_env_any, 0, 0, "")

	## Read the system clipboard. It often holds text the user copied from
	## somewhere else entirely, such as a password.
	clipboard_read : Permission
	clipboard_read = declare(kind_clipboard_read, 0, 0, "")

	## Replace the system clipboard's contents.
	clipboard_write : Permission
	clipboard_write = declare(kind_clipboard_write, 0, 0, "")

	## Use the directory the app was launched from, and everything beneath it.
	##
	## This is what running an example from a repository checkout wants: its
	## assets are found relative to where the command ran. Paths that climb out
	## of it with `..` are not covered.
	working_directory : Mode -> Permission
	working_directory = |mode| declare(kind_working_directory, mode_code(mode), 0, "")

	## Use one directory and everything beneath it. An absolute path names it
	## directly; a relative one is resolved against the working directory. The
	## path may not contain `..` and may not be the filesystem root.
	directory : Str, Mode -> Permission
	directory = |path, mode| declare(kind_directory, mode_code(mode), 0, path)

	## Use any path on the filesystem.
	files_anywhere : Mode -> Permission
	files_anywhere = |mode| declare(kind_files_anywhere, mode_code(mode), 0, "")

	## Internal bridge to the flat record the host validates at startup.
	for_host : Permission -> { kind : U8, mode : U8, port : U16, text : Str }
	for_host = |Permission.(fields)| fields
}

declare : U8, U8, U16, Str -> Permission
declare = |kind, mode, port, text| Permission.({ kind, mode, port, text })

mode_code : Permission.Mode -> U8
mode_code = |mode|
	match mode {
		ReadOnly => 0
		ReadWrite => 1
	}

# Transport codes, mirrored by `Kind` in `src/permissions.zig`.
kind_http_origin : U8
kind_http_origin = 1

kind_http_any : U8
kind_http_any = 2

kind_udp_bind : U8
kind_udp_bind = 3

kind_udp_peer : U8
kind_udp_peer = 4

kind_udp_any : U8
kind_udp_any = 5

kind_command : U8
kind_command = 6

kind_command_any : U8
kind_command_any = 7

kind_env_var : U8
kind_env_var = 8

kind_env_any : U8
kind_env_any = 9

kind_clipboard_read : U8
kind_clipboard_read = 10

kind_clipboard_write : U8
kind_clipboard_write = 11

kind_working_directory : U8
kind_working_directory = 12

kind_directory : U8
kind_directory = 13

kind_files_anywhere : U8
kind_files_anywhere = 14

expect Permission.for_host(Permission.http_origin("https://api.example.com")).text == "https://api.example.com"
expect Permission.for_host(Permission.udp_peer("127.0.0.1", 9000)) == { kind: 4, mode: 0, port: 9000, text: "127.0.0.1" }
expect Permission.for_host(Permission.directory("/srv/data", ReadWrite)) == { kind: 13, mode: 1, port: 0, text: "/srv/data" }
expect Permission.for_host(Permission.working_directory(ReadOnly)).kind == 12
