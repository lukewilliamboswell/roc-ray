## Private typed ARC identities shared by public adapters and hosted declarations.
## Only the host creates live resources; the public APIs supply resource-free stubs.
Resource := [].{

	## Host-issued application-lifetime authority. Its representation never escapes the platform.
	Authority :: U64.{

		## Inert value for pure tests; never accepted by the host.
		stub : Authority
		stub = Authority.(0)
	}

	Handle(_resource) :: Box(U64).{
		is_eq : Handle(_resource), Handle(_resource) -> Bool
		is_eq = |Handle.(a), Handle.(b)| Box.unbox(a) == Box.unbox(b)

		to_hash : Handle(_resource), Hasher -> Hasher
		to_hash = |Handle.(value), hasher| U64.to_hash(Box.unbox(value), hasher)

		## Resource-free handle for pure tests.
		##
		## This value never resolves to a host resource. Public adapters use it to
		## construct their documented test stubs; it must not be used to test host
		## operations or resource lifetime.
		stub : Handle(_resource)
		stub = Handle.(Box.box(U64.highest))
	}

	# Closed phantom tags keep handle kinds distinct without extra runtime data.
	Sound : Handle([SoundResource])

	Music : Handle([MusicResource])

	Db : Handle([SqliteDbResource])

	Stmt : Handle([SqliteStmtResource])

	Prepared : Handle([PreparedTextResource])

	Store : Handle([StoreResource])

	Shader : Handle([ShaderResource])

	Socket : Handle([UdpSocketResource])

	Texture : Handle([TextureResource])

	Font : Handle([FontResource])
}
