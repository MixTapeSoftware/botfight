# State-machine review

Model each piece of stateful code the head changes as a finite state machine, then check the machine's integrity. Bugs in UI flows and branching logic usually hide in a combination nobody listed: a state with no way out, two flags that should never be true together, an event arriving in a state that never expected it. Writing the machine down makes those combinations visible.

## What to model

Model every changed unit that holds or derives state:

- **UI elements**: components, screens, dialogs, forms, wizards, menus, and multi-step flows. States are what the user can see and do; events are user actions plus everything that happens to the element (async responses, errors, timeouts, navigation, unmount).
- **Logic**: boolean flags, status fields, nullable fields read as state (`data`, `error`), nested conditionals, early returns, retry and polling loops, async lifecycles, and reducers. Convert each into explicit states and transitions; `n` interacting booleans form `2^n` candidate states, and every one of them gets classified.

Include the code the change reads and writes, not only the diff lines: a new event handler is a new transition in a machine defined elsewhere.

## Building the machine

1. **States**: enumerate every state the code can represent. For flags and nullable fields, list each combination.
2. **Initial state**: identify where the machine starts and what a reset returns to.
3. **Events**: list every input: user actions, responses (success, failure, empty, slow), timers, cancellation, navigation away, unmount, and repeats of the same event.
4. **Transitions**: from handlers, branches, and effects, record `state + event (+ guard) → state` and the side effects each one runs.
5. **Table**: build the full `state × event` table. Each cell holds a transition, or is marked deliberately ignored with the code that ignores it.

The machine is complete when every state is classified (reachable and legal, reachable and illegal, or unreachable) and every cell of the table is filled.

## Integrity checks

Check the complete machine for each defect below. A defect becomes a finding when you can trace a concrete event sequence from the initial state to it.

- **Dead end**: a non-terminal state with no exit. A spinner that never leaves on error, a disabled button nothing re-enables, a modal with no close path, a loop with no exit condition.
- **Impossible state reached**: a combination the domain forbids becomes reachable, such as `isLoading && isError`, `data` and `error` both set, or "submitted" with an empty form.
- **Unhandled event**: an event arriving in a state that does not expect it. Double submit, a click during loading, a late response after cancel or unmount overwriting newer state, back-navigation mid-flow.
- **Nondeterminism**: two transitions for the same state and event with overlapping guards, or a guard chain with a gap (an `if / else if` with no final branch that the inputs can reach).
- **Unreachable state**: code that handles a state no transition reaches. Either a transition is missing or the handling is dead code.
- **No recovery**: an error or partial state with no path back to idle, retry, or a terminal state.
- **Dirty reset**: a reset or re-entry that leaves stale fields, timers, subscriptions, or focus from the previous pass.
- **Leaky exit**: an effect started on entering a state (timer, subscription, request, listener) with no cleanup on leaving it.

An illegal state that the code can represent but no sequence reaches is a design weakness, not a live bug. Report it only as a lower-importance finding suggesting a representation that rules it out, such as a status enum or discriminated union in place of independent flags.

## Reporting

Anchor each finding at the line that creates the defect: the missing branch, the flag write, the handler without a guard. The inline comment states:

- The defect type from the list above.
- The trace: the shortest event sequence from the initial state to the defect, written as `state —event→ state —event→ …`.
- What the user sees or what breaks there.
- The correction: the missing transition, guard, or cleanup, or the state representation that makes the defect unrepresentable.

Score reachable dead ends, impossible states, and lost or corrupted user data in a user-facing flow at 6 or above. Score representable-but-unreachable states and cosmetic transient states below 6.

In the review summary, include each modelled machine's transition table inside a collapsed `<details>` block titled with the unit's name, so the fixer and human reviewers can check the model the findings rest on. When the head changes no stateful code within the scope, state that in the summary instead.
