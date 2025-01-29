module [
    NonEmptyList,
    new,
    first,
    last,
    find_last,
    find_first,
    map,
    to_list,
    drop_non_last_if,
    append,
    append_all,
    update_non_last,
    sort_with,
    from_list,
    walk_until,
]

## A List guaranteed to contain at least one item
NonEmptyList a := Inner a

Inner a : {
    list : List a,
    last : a,
}

new : a -> NonEmptyList a
new = |item|
    @NonEmptyList({ list: [], last: item })

first : NonEmptyList a -> a
first = |@NonEmptyList(inner)|
    when List.first(inner.list) is
        Ok(f) -> f
        Err(ListWasEmpty) -> inner.last

last : NonEmptyList a -> a
last = |@NonEmptyList(inner)|
    inner.last

find_last : NonEmptyList a, (a -> Bool) -> Result a [NotFound]
find_last = |@NonEmptyList(inner), is_match|
    if is_match(inner.last) then
        Ok(inner.last)
    else
        List.find_last(inner.list, is_match)

find_first : NonEmptyList a, (a -> Bool) -> Result a [NotFound]
find_first = |@NonEmptyList(inner), is_match|
    when List.find_first(inner.list, is_match) is
        Ok(found) -> Ok(found)
        Err(NotFound) ->
            if is_match(inner.last) then
                Ok(inner.last)
            else
                Err(NotFound)

map : NonEmptyList a, (a -> b) -> NonEmptyList b
map = |@NonEmptyList(inner), transform|
    new_list = List.map(inner.list, transform)
    new_last = transform(inner.last)
    @NonEmptyList({ list: new_list, last: new_last })

to_list : NonEmptyList a -> List a
to_list = |@NonEmptyList(inner)|
    inner.list
    |> List.append(inner.last)

from_list : List a -> Result (NonEmptyList a) [ListWasEmpty]
from_list = |original|
    when List.last(original) is
        Err(ListWasEmpty) -> Err(ListWasEmpty)
        Ok(last_item) ->
            non_last = List.drop_last(original, 1)
            Ok(@NonEmptyList({ list: non_last, last: last_item }))

## Drop items from the list matching a predicate
## But keep the last item in the list regardless of whether it passes
drop_non_last_if : NonEmptyList a, (a -> Bool) -> NonEmptyList a
drop_non_last_if = |@NonEmptyList(inner), should_drop|
    list = List.drop_if(inner.list, should_drop)
    @NonEmptyList({ inner & list })

update_non_last : NonEmptyList a, (List a -> List a) -> NonEmptyList a
update_non_last = |@NonEmptyList(inner), update|
    list = update(inner.list)
    @NonEmptyList({ inner & list })

append : NonEmptyList a, a -> NonEmptyList a
append = |@NonEmptyList(inner), item|
    @NonEmptyList(
        {
            last: item,
            list: List.append(inner.list, inner.last),
        },
    )

append_all : NonEmptyList a, List a -> NonEmptyList a
append_all = |@NonEmptyList(inner), items|
    when List.last(items) is
        Err(ListWasEmpty) -> @NonEmptyList(inner)
        Ok(new_last) ->
            new_non_last = List.take_first(items, (List.len(items) - 1))
            @NonEmptyList(
                {
                    last: new_last,
                    list: List.concat(inner.list, new_non_last),
                },
            )

sort_with : NonEmptyList a, (a, a -> [LT, EQ, GT]) -> NonEmptyList a
sort_with = |non_empty, compare|
    full_list = to_list(non_empty)
    sorted = List.sort_with(full_list, compare)

    non_last = List.drop_last(sorted, 1)
    last_item =
        when List.last(sorted) is
            Err(_) -> crash("unreachable")
            Ok(item) -> item

    @NonEmptyList({ list: non_last, last: last_item })

Step state : [Break state, Continue state]

walk_until : NonEmptyList item, (item -> Step state), (state, item -> Step state) -> state
walk_until = |non_empty, from_first, step|
    list = to_list(non_empty)

    WrappedState s : [Empty, SeenOne s]

    wrapped_initial : WrappedState state
    wrapped_initial = Empty

    walked =
        List.walk_until(
            list,
            wrapped_initial,
            |wrapped_state, item|
                when wrapped_state is
                    Empty ->
                        when from_first(item) is
                            Break(s) -> Break(SeenOne(s))
                            Continue(s) -> Continue(SeenOne(s))

                    SeenOne(state) ->
                        when step(state, item) is
                            Break(s) -> Break(SeenOne(s))
                            Continue(s) -> Continue(SeenOne(s)),
        )

    when walked is
        Empty -> crash("unreachable")
        SeenOne(state) -> state
