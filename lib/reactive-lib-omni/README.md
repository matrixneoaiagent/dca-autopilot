# reactive-lib-omni (vendored dependency)

These files are the Reactive Network `reactive-lib-omni` base contracts
(`AbstractReactive`, `AbstractCallback`, `AbstractPayer`, and the system
interfaces), vendored so the repository builds without network access.

They retain their upstream SPDX headers (`UNLICENSED`) and are **not** covered
by this repository's MIT licence. The DCA Autopilot contracts in `src/` are the
original work for this build; the dependency supplies the standard Reactive
subscription, callback-payer and authentication primitives.
