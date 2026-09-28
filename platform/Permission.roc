## What an app may access beyond its own resources.
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
##     .with_permission(HttpOrigin("https://api.example.com"))
##     .with_permission(EnvVar("WEATHER_TOKEN"))
## ```
##
## There is no launch flag that widens this, so what an app can access is
## visible in its source and changed only by changing its source.
##
## Declare each facility as narrowly as it allows. An origin, a port, a program
## name, a variable name, or a directory is a scope: an effect whose target
## falls outside every declared scope returns `PermissionDenied` without doing
## anything, because a URL or path can be runtime data. `PermissionDenied`
## means only that: no declaration covers the target. A path refused for its
## shape -- one with `..` that no declaration can cover, or one that meets a
## symbolic link beneath a handle -- is `PathInvalid` instead, because the fix
## is to the path, not to the declarations.
##
## Using a facility the app never declared at all is a programmer error: the
## app stops at once with a message naming the declaration to add. A malformed
## declaration -- a directory with `..`, a peer that is not an IPv4 address --
## stops the app before `init!`.
##
## A declaration is platform policy, not an operating-system sandbox: it limits
## what Roc code in the app can access, because that code has no way to access
## anything except through the platform.
import Url

## One declaration.
##
## **HTTP**
##
## - `HttpOrigin(url)`: send requests to the URL's origin -- its scheme, host,
##   and port. Any path or query in the URL is not part of the declaration.
##   `HttpOrigin("https://api.example.com")` permits
##   `https://api.example.com/v1/forecast` but not `http://api.example.com`,
##   `https://api.example.com:8443`, or `https://cdn.example.com`. A redirect
##   to another origin is refused unless that origin is declared too.
## - `HttpAny`: send requests anywhere. Prefer `HttpOrigin` unless the app's
##   destinations truly are open-ended, such as a user-typed URL.
##
## **UDP**
##
## - `UdpBind(port)`: bind a socket to one local port.
## - `UdpPeer(address, port)`: send datagrams to one IPv4 peer, written as a
##   dotted quad such as `"192.168.1.20"`. Also permits binding an ephemeral
##   port (port `0`) to talk to it.
## - `UdpLoopback`: bind and send on any port of any address in `127.0.0.0/8`,
##   which is networking between processes on this machine and nothing beyond.
## - `UdpAny`: bind any port and send to any peer.
##
## **Programs**
##
## - `Command(program)`: run one program, named exactly as the app names it to
##   `Cmd`. `Command("git")` permits running `"git"`, looked up on `PATH`, and
##   not `"/usr/bin/git"` or anything else.
## - `CommandAny`: run any program. A child process has all of the user's
##   authority, so this is the widest declaration there is.
##
## **Environment**
##
## - `EnvVar(name)`: read one environment variable by exact name.
## - `EnvAny`: read any environment variable.
##
## **Clipboard**
##
## - `ClipboardRead`: read the system clipboard, which often holds text the
##   user copied from somewhere else entirely, such as a password.
## - `ClipboardWrite`: replace the system clipboard's contents.
##
## **Files**
##
## - `WorkingDirectory(mode)`: the directory the app was launched from, and
##   everything beneath it -- what running an example from a repository
##   checkout wants. It covers every relative path an app gives
##   `Files.Access.open_dir!`; a path that climbs out with `..` is
##   `PathInvalid`.
## - `Directory(path, mode)`: one directory and everything beneath it. It may
##   not contain `..` or be the filesystem root.
## - `FilesAny(mode)`: any path on the filesystem, `..` included.
##
## A `mode` is `ReadOnly` or `ReadWrite`.
##
## Whether a `Directory` covers a path is decided from the text of both, not by
## asking the filesystem. An absolute declaration covers absolute paths beneath
## it, and a relative declaration covers relative paths beneath it, component
## by component: `Directory("saves", ReadWrite)` covers `open_dir!("saves")`
## and `open_dir!("saves/slot1")`, and not `open_dir!("savesX")` or the same
## directory spelled as an absolute path. Both kinds of path are opened
## relative to the working directory when they are relative.
##
## Each facility's unscoped form -- `HttpAny`, `UdpAny`, `CommandAny`,
## `EnvAny`, `FilesAny` -- is spelled to stand out in review.
Permission := [
	HttpOrigin(Url),
	HttpAny,
	UdpBind(U16),
	UdpPeer(Str, U16),
	UdpLoopback,
	UdpAny,
	Command(Str),
	CommandAny,
	EnvVar(Str),
	EnvAny,
	ClipboardRead,
	ClipboardWrite,
	WorkingDirectory([ReadOnly, ReadWrite]),
	Directory(Str, [ReadOnly, ReadWrite]),
	FilesAny([ReadOnly, ReadWrite]),
].{

	## Compare two declarations.
	is_eq : _
}
