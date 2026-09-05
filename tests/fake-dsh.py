#!/usr/bin/env python3
"""Local protocol fixture: no network, credentials, or source mutations."""
import json
import os
from pathlib import Path
import sys
import time

args = sys.argv[1:]
scenario = os.environ.get('CRIT_MAGIT_TEST_SCENARIO', 'normal')
if args[args.index('--profile') + 1] == 'acp':
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get('method')
        if not method:
            continue
        if scenario == 'hang':
            continue
        if method == 'initialize':
            result = {'protocolVersion': 1, 'agentCapabilities': {}}
        elif method == 'session/new':
            result = {'sessionId': 'test', 'configOptions': [{
                'id': 'model', 'type': 'select',
                'currentValue': '["test-provider","test-model"]',
                'options': [{'name': 'Test', 'value': '["test-provider","test-model"]'}]
            }]}
        elif method == 'session/close':
            if scenario == 'no-close':
                print(json.dumps({'jsonrpc': '2.0', 'id': request['id'],
                                  'error': {'code': -32601, 'message': 'unsupported'}}), flush=True)
                continue
            result = {}
        response = json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result})
        # Deliberately fragment the JSON stream.
        sys.stdout.write(response[:7])
        sys.stdout.flush()
        time.sleep(.01)
        sys.stdout.write(response[7:] + '\n')
        sys.stdout.flush()
else:
    if scenario == 'review-hang':
        time.sleep(30)
    if scenario == 'review-error':
        print('fixture review failure', file=sys.stderr, flush=True)
        sys.exit(7)
    prompt = args[-1]
    request_path = None
    if prompt.startswith('Read the complete review request in '):
        request_path, _ = json.JSONDecoder().raw_decode(prompt[len('Read the complete review request in '):])
        prompt = Path(request_path).read_text(encoding='utf-8')
    patch_path = args[args.index('--patch') + 1]
    print(json.dumps({'prompt': prompt, 'request_path': request_path,
                      'patch_path': patch_path, 'patch': Path(patch_path).read_text(),
                      'cwd': os.getcwd()}, ensure_ascii=False), flush=True)
