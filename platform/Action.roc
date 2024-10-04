module [Action, none, update, map]

Action state : [
    None,
    Update state,
]

none : Action *
none = None

update : state -> Action state
update = Update

map : Action a, (a -> b) -> Action b
map = \action, transform ->
    when action is
        None -> None
        Update state -> Update (transform state)

# TODO can we implement this??
# fromTask : Task ok err, (Result ok err -> (Result state [Removed]* -> Action state)) -> Action state
