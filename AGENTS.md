# RocRay agent guidelines

## Architectural authority

- Read `design.md` completely before proposing or making changes to public
  APIs, platform behavior, host integration, ownership, scheduling, resource
  limits, targets, or application lifecycle.
- Treat `design.md` as the authoritative description of RocRay's intended
  end-state architecture. The current implementation may lag behind it. Move
  the implementation toward the design; do not use existing conflicting code
  as evidence that the conflict is intentional.
- Evaluate code, tests, examples, and documentation against the design's scope,
  boundaries, vocabulary, invariants, and non-goals. A locally convenient
  implementation is not acceptable if it weakens the application contract.
- If requested work conflicts with the design, identify the conflict
  explicitly. Do not hide it behind compatibility glue, a special case, or an
  undocumented new boundary protocol.
- Change `design.md` only when requirements deliberately change, experience
  invalidates an architectural assumption, or the system boundary is
  intentionally moved. Do not edit it merely to legitimize current behavior or
  an implementation shortcut.

## Review every change through the boundary

- Keep application domain state and policy in Roc. The host may retain the
  opaque model between callbacks, but must not inspect it, mutate it, or infer
  application decisions from it.
- Classify every application/host interaction as one of the four protocols in
  `design.md`: startup authority, `App.Input`, a direct host effect called from
  `update!` or a task, or `Draw.Frame`. Adding another interaction shape is an
  architecture change, not an ordinary feature.
- Keep application callbacks serial and on one thread. Host workers must not
  execute Roc application code or share Roc values across threads unsafely.
- Keep a synchronous effect current-cycle. Keep a task accountable for exactly
  one message during an orderly application lifetime. Never silently discard a
  task's message or a non-lossy input event.
- Keep rendering derived from the resulting model and scoped by `Draw.Frame`.
  Rendering must not become a second model transition or a route to general
  host work.
- Establish bounds before admitting host-retained work. Define what is counted,
  reservation and release points, saturation behavior, retained payload size,
  and shutdown behavior. Do not introduce an implicit unbounded queue, cache,
  registry, worker set, or callback set.
- Keep programmer errors distinct from runtime outcomes. Make invalid values
  unrepresentable where practical, reject a structurally invalid call before it
  reaches the host, and return mutable external conditions as typed data. Do not silently repair, substitute, retry, downgrade, or ignore a
  condition that can change application meaning.
- Represent host authority with typed opaque capabilities. Do not expose native
  pointers, transport tickets, untyped IDs, arbitrary native calls, or
  effectful closures. Resource and memory safety must not depend on an
  application remembering manual cleanup.
- Preserve honest capability profiles. Structurally unsupported facilities are
  absent from a target; runtime unavailability of a supported facility is a
  typed outcome.
- Keep target and backend details below the public contract. Native, browser,
  headless, and future hosts may schedule differently but must preserve the
  semantics they claim.

## Use the architecture vocabulary consistently

- Use the terms defined in `design.md` according to their direction, timing,
  ownership, and cardinality. In particular, distinguish host cycles,
  simulation steps, and presentation frames.
- For the intended public model, use `Input`, `Request`, `Task`, `Message`,
  and `Frame`; use `update!` for the effectful step that folds an input into
  the next model, *effect* for a direct host call it makes, and *phase* for
  the callback (`init!`, `update!`, `render!`, a task) the host checks an
  effect against.
- Do not introduce `Step`, `Action`, `Task`, `Update`, `static`, or `commit` as
  alternate public names for those concepts. Existing uses are migration work,
  not naming precedent.
- Choose new terms by their established meaning and by what a user can infer
  from the name. Prefer familiar qualified language over novel vocabulary, but
  do not reuse a familiar word with reversed direction or surprising lifecycle
  semantics.
- Name operations according to the strength of their guarantee. Reserve `Set`
  for changes the capability contract can enforce; use language such as
  `Suggest` for best-effort host or window-manager behavior.

## Complete work across affected layers

- Follow `CONTRIBUTING.md` for the current repository layout, development
  workflow, and verification commands rather than duplicating volatile details
  here.
- Trace a boundary change through every affected public Roc type, adapter,
  hosted declaration, ABI representation, native host path, backend, target
  profile, test, example, and user-facing document. Keep transport
  representations private.
- Verify architectural behavior, not only the successful path. Test ordering,
  saturation, refusal, response cardinality, ownership transfer, shutdown,
  phase enforcement, and target-profile behavior as applicable.
- Preserve unrelated user changes and do not broaden the task merely because a
  nearby implementation differs from the design. Report additional migration
  work separately.

## Keep this file enduring

- `AGENTS.md` contains repository-wide principles and review guardrails only.
  It is not a notebook, changelog, roadmap, task tracker, handoff document, or
  memory store.
- Do not add issue or pull-request status, implementation progress, temporary
  workarounds, investigation logs, benchmark results, command transcripts,
  current compiler defects, one-off file instructions, TODO lists, or lessons
  relevant only to a completed task.
- Put stable architectural requirements and rationale in `design.md`; current
  development workflow in `CONTRIBUTING.md`; public API behavior in module
  documentation; implementation invariants beside the code they constrain; and
  plans, status, and temporary findings in issues or pull requests.
- Add or change an instruction here only when it should govern unrelated future
  work across the repository. If an instruction is likely to expire when one
  feature, migration, or bug is finished, it does not belong here.
