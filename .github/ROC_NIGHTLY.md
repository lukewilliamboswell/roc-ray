# Roc nightly updates

This repository checks once daily at 13:40 UTC, about four hours
after the upstream 09:00 UTC build. Late publication can wait until the next day.

The compiler pins live in `platform/main.roc` and `platform/main-wayland.roc`.
`.github/roc-nightly.json` limits updates to those development roots and selects
the validation workflows, including their validation-only release paths.
Public example compiler pins and release URLs are updated separately.
The controller, its tests, and job permissions are maintained in
[roc-automation](https://github.com/lukewilliamboswell/roc-automation).
The caller workflows pin shared code to `1c26abc3dda359c5c031303563167bfa43ad6e32`.
Dependabot proposes reviewed updates to Actions/workflow references.

Follow the shared [integration and permissions guide](https://github.com/lukewilliamboswell/roc-automation/blob/1c26abc3dda359c5c031303563167bfa43ad6e32/docs/integration.md)
for the PR-creation setting, action allowlists, required checks, and first live
GITHUB_TOKEN run. Keep default token permissions read-only. The updater never
approves or merges PRs and receives no protection bypass.

`automation/roc-nightly` is reserved for the bot's pin-only commits. Put manual
compatibility changes on a separate branch. Candidate failures require diagnosis;
do not weaken tests or mechanically replace baselines to accept a compiler.

The PR configuration check validates the local pin and selected workflow files.
The shared repository owns the controller regression suite. Project tests remain
in this repository and run on the exact candidate commit. Scheduled bot-token
acceptance must be verified after merge; file changes alone cannot prove it.

Use the shared [OpenSSF rollout checklist](https://github.com/lukewilliamboswell/roc-automation/blob/1c26abc3dda359c5c031303563167bfa43ad6e32/docs/openssf.md)
to record project-specific evidence. This integration does not establish badge
compliance or change repository settings.
