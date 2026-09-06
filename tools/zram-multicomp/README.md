# ZRAM multi-comp resolver (Phase 1)

`resolve.sh` freezes an exact target identity for **fixed test fixtures only**.
It requires `--fixture` and emits `resolution_status: fixture-ready`; this is
not a claim that `7.0.14-16-pve` (or any other target) has a verified source,
package, or boot-tested module.  A `trust.verified_by` property in JSON is
provenance text, never a trust decision.

`authenticated-evidence.py` implements the real Phase-1 publication boundary.
It verifies `InRelease` with an explicit keyring, verifies `Packages.gz` against
the signed SHA-256 entry, requires one exact index stanza for each requested
`NAME=VERSION`, verifies both deb hashes and their control fields, then extracts
`SOURCE`, `.config` and `Module.symvers`. Native `dpkg-deb` is preferred; the
rootless, network-disabled Podman invocation is only a Fedora extraction
fallback. The record includes the keyring digest and its supplied provenance.
It never treats `SOURCE` as executable code. Exact source evidence is required
before a build: the adapter reports `waiting-source` rather than inventing a
snapshot or patch list.

`ensure-headers.sh` is a separate CLI, never a kernel postinst hook. Fixture
manifests can never install headers. Real manifests currently only print the
exact request: installation remains disabled until Phase 3 validates dpkg/apt
locking and initramfs concurrency.
