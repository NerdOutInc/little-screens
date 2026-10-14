#!/usr/bin/env python3
"""Token-authenticated Site client. Credentials stay in an ignored local file."""
import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', type=Path, default=Path('.runtime/site-connection.json'))
    s = p.add_subparsers(dest='command', required=True)
    s.add_parser('list')
    s.add_parser('guide')
    get = s.add_parser('get'); get.add_argument('id')
    receipt = s.add_parser('receipt'); receipt.add_argument('request_id')
    download = s.add_parser('download'); download.add_argument('id'); download.add_argument('kind', choices=['image', 'scene', 'reference']); download.add_argument('output', type=Path)
    write = s.add_parser('write'); write.add_argument('action', choices=['save_screen', 'save_scene', 'publish_screen']); write.add_argument('input', type=Path); write.add_argument('--png', type=Path, help='Read image bytes without putting base64 into conversation text')
    args = p.parse_args()
    config = json.loads(args.config.read_text())
    origin = config['origin'].rstrip('/')
    parsed = urllib.parse.urlsplit(origin)
    if parsed.scheme != 'https' and not (parsed.scheme == 'http' and parsed.hostname in ('localhost', '127.0.0.1')):
        raise ValueError('Use an HTTPS Site origin (HTTP permitted only for localhost development)')
    if parsed.path or parsed.query or parsed.fragment or parsed.username or parsed.password:
        raise ValueError('Use an origin only, without a path, query, or embedded credentials')
    if os.name != 'nt' and args.config.stat().st_mode & 0o077:
        raise ValueError('Connection file must be private: chmod 600 ' + str(args.config))
    headers = {'Authorization': 'Bearer ' + config['token']}
    # Optional short-lived owner preview access during private deployment QA only.
    if config.get('preview_bypass'):
        headers['OAI-Sites-Authorization'] = 'Bearer ' + config['preview_bypass']
    data = None
    if args.command == 'write':
        payload = json.loads(args.input.read_text())
        if args.png:
            payload['png_base64'] = base64.b64encode(args.png.read_bytes()).decode()
        data = json.dumps(payload).encode()
        headers['Content-Type'] = 'application/json'
        path = args.action
    elif args.command == 'list': path = 'screens'
    elif args.command == 'guide': path = 'guide'
    elif args.command == 'get': path = 'screens/' + urllib.parse.quote(args.id, safe='')
    elif args.command == 'receipt': path = 'receipts/' + urllib.parse.quote(args.request_id, safe='')
    else: path = 'assets/' + urllib.parse.quote(args.id, safe='') + '/' + args.kind
    request = urllib.request.Request(origin + '/api/' + path, data=data, headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=45) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        print(json.dumps({'error': 'Site returned HTTP ' + str(error.code), 'detail': error.read(1000).decode(errors='replace')}), file=sys.stderr)
        raise SystemExit(1)
    if args.command == 'download':
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(raw)
        print(json.dumps({'saved': str(args.output), 'bytes': len(raw)}))
    else:
        result = json.loads(raw)
        # Setup/image URLs embed device keys. The updater does not need to print them.
        def redact(value):
            if isinstance(value, dict): return {k: redact(v) for k, v in value.items() if k not in ('setup_url', 'image_url')}
            if isinstance(value, list): return [redact(v) for v in value]
            return value
        print(json.dumps(redact(result), indent=2))

if __name__ == '__main__':
    main()
