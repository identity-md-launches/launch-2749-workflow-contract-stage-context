# Vendored dependencies

All build and test dependencies are ordinary source files in `lib/`. No install,
network connection, submodule, FFI, external library link, or filesystem cheatcode
permission is needed to run the default build and tests.

| Dependency | Version | Included files | Upstream |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | 5.0.2 | Transitive source closure of ERC20, ERC721 (test mock), Ownable2Step, ReentrancyGuard, IERC721Receiver, SafeERC20, Math; MIT licence | https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2 |
| forge-std | 1.9.7 | `src/`, MIT and Apache licences | https://github.com/foundry-rs/forge-std/tree/v1.9.7 |

The application itself was authored for this assignment. It does not import or
compile Squeekchain's project. `src/interfaces/IGraphA.sol` describes only the
external methods used by the vault and its integration tests.

`test/fixtures/GraphASnapshot.sol` contains original external contract runtime
bytes and accessed storage from Sepolia block 12,019,224. This is test data, not
an application implementation or deployable dependency. The original verified
Graph A sources identify their licence as MIT. OpenZeppelin's licence is included
at `lib/openzeppelin-contracts/LICENSE`. Runtime checksums and snapshot provenance
are recorded in `test/fixtures/graph-a-snapshot.json`.

Verified Graph A ABI/source references:

- Mining v6 implementation: https://sourcify.dev/server/v2/contract/11155111/0x08890b360C65FD878344Bf6e23d1c36358433B4E?fields=all
- Mining proxy: https://sourcify.dev/server/v2/contract/11155111/0x3beE588fC20dE788Bac17d33b41Da7346cb27EC4?fields=all
- Core proxy: https://sourcify.dev/server/v2/contract/11155111/0x74665dAecA35A2303e767E76a2FF1FB6F93e119f?fields=all
- SqueekNFT: https://sourcify.dev/server/v2/contract/11155111/0x0eAF3E0d40A0a8E5a6Ac030b2459E9FB0B7905c6?fields=all

The supplied eth-security reference was used as a checklist. It is not a library
or runtime dependency and does not confer an audit or deployment approval.
