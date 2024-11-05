module [Rollback, checksum, advance]

Rollback implements
    ## compute a digest or hash identifying the current simulation state
    checksum : state -> I64 where state implements Rollback
    ## advance one simulation frame
    advance : state, context -> (gs, U64) where state implements Rollback
