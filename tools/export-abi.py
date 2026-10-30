#!/usr/bin/env python3
"""Export compiled public ABIs without introducing a package dependency.
Run forge build before this command. --check verifies the checked-in exports.
"""
import argparse
import json
from pathlib import Path

CONTRACTS = {
    'HamsterMiningReserve': 'HamsterMiningReserve.sol',
    'IGraphAMining': 'IGraphA.sol',
    'IGraphACore': 'IGraphA.sol',
    'IGraphANFT': 'IGraphA.sol',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for name, source in CONTRACTS.items():
        artifact = Path('out') / source / f'{name}.json'
        abi = json.loads(artifact.read_text())['abi']
        destination = Path('docs/abi') / f'{name}.json'
        content = json.dumps(abi, indent=2) + '\n'
        if args.check:
            if destination.read_text() != content:
                raise SystemExit(f'{destination} is stale; run python3 tools/export-abi.py')
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(content)
        print(f'{destination}: {len(abi)} entries')


if __name__ == '__main__':
    main()
