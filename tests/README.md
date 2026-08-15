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

Run design-regression tests separately:

```sh
make test-regression
```

The copied runtime currently fails non-ancestor shared table references, even
for one shared object. The same defect also affects larger graphs. The test is
kept red intentionally so the new implementation has an executable acceptance
case for the issue documented in `DESIGN.md`.
