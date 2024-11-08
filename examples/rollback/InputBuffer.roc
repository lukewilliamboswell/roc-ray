module [
    InputBuffer,
    capacity,
    contents,
    new,
    fromList,
    first,
    last,
    push,
    pushAll,
    dropOldestWhile,
    findLatest,
]

## A non-empty ring buffer for player inputs
InputBuffer a := Buffer a

Buffer a : {
    ## the backing list
    ## its contents are read from oldest to latest, wrapping around
    list : List (Result a [EmptySlot]),

    ## the first added item
    ## the slot `List.get list oldest` is guaranteed to have the first added item
    oldest : U64,

    ## the last added item
    ## the slot `List.get list latest` is guaranteed to have the last added item
    latest : U64,
}

capacity : U64
capacity = 256

new : a -> InputBuffer a
new = \item ->
    fromList item []

fromList : a, List a -> InputBuffer a
fromList = \firstItem, rest ->
    oldest = 0
    latest = List.len rest

    original = List.prepend rest firstItem
    fullSlots =
        List.takeFirst original capacity
        |> List.map Ok
    emptySlots =
        List.repeat (Err EmptySlot) (capacity - List.len fullSlots)
    list = List.concat fullSlots emptySlots

    @InputBuffer { oldest, latest, list }

## access the first / oldest item, which is guaranteed to be present
first : InputBuffer a -> a
first = \@InputBuffer buffer ->
    when List.get buffer.list buffer.oldest is
        Ok (Ok item) -> item
        _ -> crash "invalid buffer"

## access the last / latest item, which is guaranteed to be present
last : InputBuffer a -> a
last = \@InputBuffer buffer ->
    when List.get buffer.list buffer.latest is
        Ok (Ok item) -> item
        _ -> crash "invalid buffer"

## Add a new item, which will become the last / latest.
## If adding an item would overflow capacity, the same buffer is returned instead.
## Letting a player get 256 frames ahead of their opponent is not advised.
push : InputBuffer a, a -> InputBuffer a
push = \@InputBuffer buffer, item ->
    buffer
    |> pushOneUnsorted item
    |> @InputBuffer

pushAll : InputBuffer a, List a -> InputBuffer a
pushAll = \@InputBuffer initialBuffer, items ->
    items
    |> List.walk initialBuffer pushOneUnsorted
    |> @InputBuffer

pushOneUnsorted : Buffer a, a -> Buffer a
pushOneUnsorted = \buffer, item ->
    latest = (buffer.latest + 1) % capacity
    if latest == buffer.oldest then
        buffer
    else
        list = List.set buffer.list latest (Ok item)
        { buffer & list, latest }

## Drop the oldest items while they meet the condition.
## Stops dropping when either condition returns false,
## or there is one latest item left in the buffer.
dropOldestWhile : InputBuffer a, (a -> Bool) -> InputBuffer a
dropOldestWhile = \@InputBuffer initialBuffer, shouldDrop ->
    indexes = deletableIndexes initialBuffer

    newBuffer =
        List.walkUntil indexes initialBuffer \buffer, i ->
            when List.get buffer.list i is
                Err OutOfBounds -> crash "invalid buffer"
                Ok (Err EmptySlot) -> crash "invalid buffer"
                Ok (Ok item) ->
                    if shouldDrop item then
                        list = List.set buffer.list i (Err EmptySlot)
                        oldest = (buffer.oldest + 1) % capacity
                        Continue ({ buffer & list, oldest })
                    else
                        Break buffer

    @InputBuffer newBuffer

findLatest : InputBuffer a, (a -> Bool) -> Result a [NotFound]
findLatest = \@InputBuffer buffer, isMatch ->
    findLast = \range ->
        List.walkBackwardsUntil range (Err NotFound) \res, i ->
            when List.get buffer.list i is
                Ok (Ok item) ->
                    if isMatch item then
                        Break (Ok item)
                    else
                        Continue res

                _ -> crash "invalid buffer"

    if buffer.oldest <= buffer.latest then
        range = List.range { start: At buffer.oldest, end: Before buffer.latest }
        findLast range
    else
        firstChunk = List.range { start: At buffer.oldest, end: Before capacity }
        secondChunk = List.range { start: At 0, end: At buffer.latest }
        when findLast firstChunk is
            Ok item -> Ok item
            Err NotFound -> findLast secondChunk

deletableIndexes : Buffer a -> List U64
deletableIndexes = \buffer ->
    if buffer.oldest <= buffer.latest then
        List.range { start: At buffer.oldest, end: Before buffer.latest }
    else
        firstChunk = List.range { start: At buffer.oldest, end: Before capacity }
        secondChunk = List.range { start: At 0, end: Before buffer.latest }
        List.concat firstChunk secondChunk

allIndexes : Buffer a -> List U64
allIndexes = \buffer ->
    if buffer.oldest <= buffer.latest then
        List.range { start: At buffer.oldest, end: At buffer.latest }
    else
        firstChunk = List.range { start: At buffer.oldest, end: Before capacity }
        secondChunk = List.range { start: At 0, end: At buffer.latest }
        List.concat firstChunk secondChunk

contents : InputBuffer a -> List a
contents = \@InputBuffer buffer ->
    List.map (allIndexes buffer) \i ->
        when List.get buffer.list i is
            Ok (Ok item) -> item
            _ -> crash "invalid buffer"

newIntBuffer : U64 -> InputBuffer U64
newIntBuffer = \num ->
    new num

expect
    justOne = newIntBuffer 1
    firstItem = first justOne
    firstItem == 1

expect
    justOne = newIntBuffer 1
    lastItem = last justOne
    lastItem == 1

expect
    ringBuffer = newIntBuffer 1 |> push 2 |> push 3
    firstItem = first ringBuffer
    firstItem == 1

expect
    ringBuffer = newIntBuffer 1 |> push 2 |> push 3
    lastItem = last ringBuffer
    lastItem == 3

expect
    ringBuffer = newIntBuffer 0
    fullBuffer =
        List.range { start: At 1, end: At (capacity - 1) }
        |> List.walk ringBuffer push

    reallyFullBuffer = push fullBuffer capacity
    actual = contents reallyFullBuffer
    expected = contents fullBuffer

    actual == expected

expect
    ringBuffer = newIntBuffer 0
    almostFullBuffer =
        List.range { start: At 1, end: At (capacity - 2) }
        |> List.walk ringBuffer push

    reallyFullBuffer = push almostFullBuffer (capacity - 1)
    actual = contents reallyFullBuffer
    almostExpected = contents almostFullBuffer

    actual != almostExpected

getInternalBuffer : InputBuffer a -> Buffer a
getInternalBuffer = \@InputBuffer buffer -> buffer

expect
    justOne = getInternalBuffer (newIntBuffer 1)
    deletable = deletableIndexes justOne
    deletable == []

expect
    justOne = newIntBuffer 1 |> push 2 |> push 3 |> getInternalBuffer
    deletable = deletableIndexes justOne
    deletable == [0, 1]

expect
    oldest = capacity - 2
    latest = 1
    list =
        List.repeat (Err EmptySlot) capacity
        |> List.set (capacity - 2) (Ok 1)
        |> List.set (capacity - 1) (Ok 2)
        |> List.set 0 (Ok 3)
        |> List.set 1 (Ok 4)

    buffer : Buffer U64
    buffer = { list, oldest, latest }

    deletable = deletableIndexes buffer
    expected = [capacity - 2, capacity - 1, 0]

    deletable == expected

expect
    ringBuffer = newIntBuffer 1 |> push 2 |> push 3 |> push 4 |> push 5
    freshBuffer = ringBuffer |> dropOldestWhile \n -> n < 3

    actual = contents freshBuffer
    expected = [3, 4, 5]

    actual == expected

expect
    ringBuffer = newIntBuffer 1 |> push 2 |> push 3 |> push 4 |> push 5
    freshBuffer = ringBuffer |> dropOldestWhile \_ -> Bool.true

    actual = contents freshBuffer
    expected = [5]

    actual == expected

expect
    ringBuffer = newIntBuffer 0

    fullBuffer =
        List.range { start: At 1, end: At (capacity - 1) }
        |> List.walk ringBuffer push

    freshBuffer = fullBuffer |> dropOldestWhile \_ -> Bool.true

    actual = contents freshBuffer
    expected = contents (newIntBuffer (capacity - 1))

    actual == expected

expect
    ringBuffer = newIntBuffer 1 |> push 2 |> push 3 |> push 4 |> push 5

    actual = findLatest ringBuffer \n -> n <= 2
    expected = Ok 2

    actual == expected

expect
    ringBuffer = newIntBuffer 1 |> push 2 |> push 3 |> push 4 |> push 5

    actual = findLatest ringBuffer \_ -> Bool.false
    expected = Err NotFound

    actual == expected

expect
    oldest = capacity - 2
    latest = 1
    list =
        List.repeat (Err EmptySlot) capacity
        |> List.set (capacity - 2) (Ok 1)
        |> List.set (capacity - 1) (Ok 2)
        |> List.set 0 (Ok 3)
        |> List.set 1 (Ok 4)

    ringBuffer : InputBuffer U64
    ringBuffer = @InputBuffer { list, oldest, latest }

    actual = findLatest ringBuffer \n -> n <= 2
    expected = Ok 2

    actual == expected

expect
    oldest = capacity - 2
    latest = 1
    list =
        List.repeat (Err EmptySlot) capacity
        |> List.set (capacity - 2) (Ok 1)
        |> List.set (capacity - 1) (Ok 2)
        |> List.set 0 (Ok 3)
        |> List.set 1 (Ok 4)

    ringBuffer : InputBuffer U64
    ringBuffer = @InputBuffer { list, oldest, latest }

    actual = findLatest ringBuffer \_ -> Bool.false
    expected = Err NotFound

    actual == expected

expect
    ringBuffer = fromList 1 [2, 3]
    list = contents ringBuffer

    list == [1, 2, 3]
