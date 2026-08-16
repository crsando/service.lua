# Tests

Run the public Lua API, native module export, and message ABI contracts:

```sh
make test-contract
```

These tests intentionally depend only on the compatibility surface, not on
the current `service_t` or queue implementation. They must remain green while
the runtime internals are replaced.

Run the baseline compatibility suite:

```sh
make test
```

The default suite includes a two-service RPC integration test covering
multi-value responses (including nil values), immediate and delayed handler
errors, nested calls, and 128 concurrently pending calls.
It also covers the exact 256-message dispatch boundary, one `on_idle` call per
dispatch round, mailbox continuation, and timer fairness under inbox backlog.
Serializer coverage includes fractional numeric keys, `__pairs`, cycles,
top-level and nested shared references, mixed cyclic graphs, and the exact
1/31/32/33/1000-object reference thresholds.

Run the standalone MPSC mailbox and service lifecycle tests:

```sh
make test-mailbox
make test-service
make test-tsan
```

The lifecycle test checks that join/free waits for an existing send pin,
stresses eight producers against retire/close/join, covers stop during startup,
closes an active luv timer and an initialized TCP handle, and verifies the
32-service/name constraints.

The original `test.lua` is preserved as `legacy/test.lua`. It is not part of
the default suite because it imports the removed `lservice2` module and mixes
manual experiments with an indefinitely running signal loop.

Run the focused historical serializer regression separately:

```sh
make test-regression
```

This target is green and runs the same shared-reference test included in the
default suite. It remains as a focused entry point for the defect documented in
`DESIGN.md` and `PROBLEM.md`.
