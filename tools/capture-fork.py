#!/usr/bin/env python3
"""Read-only JSON-RPC recording proxy for reproducible Graph A integration fixtures.

Usage: python3 tools/capture-fork.py --upstream https://sepolia.rpc.sentio.xyz \
    --output test/scratch/graph-a-rpc.json
Then run the fork profile against http://127.0.0.1:18545 at block 12019224.
The proxy refuses every method except the chain reads Foundry needs. No signing,
transaction broadcasts, private keys, environment access, or package dependencies.
"""
import argparse
import http.server
import json
from pathlib import Path
import threading
import urllib.error
import urllib.request

ALLOWED = {
    'eth_chainId', 'eth_getBlockByNumber', 'eth_getBlockByHash',
    'eth_getBalance', 'eth_getCode', 'eth_getStorageAt', 'eth_getTransactionCount',
    'net_version', 'eth_gasPrice', 'eth_blockNumber',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--port', type=int, default=18545)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()
    upstream_slots = threading.Semaphore(4)
    records = json.loads(args.output.read_text()) if args.output.exists() else {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            payload = [self.rpc(x) for x in request] if isinstance(request, list) else self.rpc(request)
            data = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except BrokenPipeError:
                pass  # The client timed out; any successful RPC response is still recorded.

        def rpc(self, request):
            method = request.get('method', '')
            if method not in ALLOWED:
                return {'jsonrpc': '2.0', 'id': request.get('id'), 'error': {'code': -32601, 'message': 'read-only recorder'}}
            key = json.dumps([method, request.get('params', [])], sort_keys=True)
            with lock:
                cached = records.get(key)
            if cached is not None:
                return dict(cached, id=request.get('id'))
            try:
                req = urllib.request.Request(args.upstream, data=json.dumps(request).encode(), headers={'Content-Type': 'application/json', 'User-Agent': 'curl/8.5.0'})
                with upstream_slots:
                    for attempt in range(3):
                        try:
                            with urllib.request.urlopen(req, timeout=15) as response:
                                result = json.load(response)
                            break
                        except (urllib.error.URLError, TimeoutError):
                            if attempt == 2:
                                raise
                if 'result' in result:
                    with lock:
                        records[key] = result
                        temporary = args.output.with_suffix('.tmp')
                        temporary.write_text(json.dumps(records, indent=2, sort_keys=True) + '\n')
                        temporary.replace(args.output)
                return result
            except (urllib.error.URLError, TimeoutError) as exc:
                return {'jsonrpc': '2.0', 'id': request.get('id'), 'error': {'code': -32000, 'message': str(exc)}}

    print(f'Read-only recorder on 127.0.0.1:{args.port}', flush=True)
    http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
