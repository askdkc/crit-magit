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
    patch_path = args[args.index('--patch') + 1] if '--patch' in args else None
    model_options = [{'id': 'model', 'type': 'select',
                      'currentValue': '["test-provider","test-model"]',
                      'options': [{'name': 'Test', 'value': '["test-provider","test-model"]'}]}]
    def update(kind, **fields):
        print(json.dumps({'jsonrpc': '2.0', 'method': 'session/update',
                          'params': {'sessionId': 'test', 'update': {
                              'sessionUpdate': kind, **fields}}}, ensure_ascii=False), flush=True)

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
            result = {'sessionId': 'test', 'configOptions': model_options}
        elif method == 'session/set_config_option':
            assert request['params']['value'] == model_options[0]['currentValue']
            if scenario == 'model-mismatch':
                model_options[0]['currentValue'] = '["wrong","model"]'
            result = {'configOptions': model_options}
        elif method == 'session/prompt':
            assert patch_path, 'Review must pass a read-only patch'
            patch = Path(patch_path).read_text()
            assert 'mode: read-only' in patch and 'policy: never' in patch
            assert 'defaultPreset: read-only' in patch
            assert os.environ['DSH_PERMISSION_MODE'] == 'read-only'
            if scenario == 'review-hang':
                time.sleep(30)
            if scenario in ('cancel-ack', 'cancel-ignore'):
                pending_prompt_id = request['id']
                update('agent_message_chunk', content={'type': 'text', 'text': 'partial review'})
                continue
            if scenario == 'review-error':
                print('fixture review failure', file=sys.stderr, flush=True)
                sys.exit(7)
            prompt = request['params']['prompt'][0]['text']
            update('agent_thought_chunk', content={'type': 'text', 'text': 'PRIVATE THOUGHT'})
            update('tool_call', title='Reading source', status='in_progress')
            print(json.dumps({'jsonrpc': '2.0', 'id': 90, 'method': 'session/request_permission',
                              'params': {'sessionId': 'test', 'options': [
                                  {'optionId': 'allow', 'kind': 'allow_once'}]}}), flush=True)
            permission = json.loads(sys.stdin.readline())
            assert permission['result']['outcome']['outcome'] == 'cancelled'
            answer = json.dumps({'prompt': prompt, 'patch_path': patch_path, 'patch': patch,
                                 'cwd': os.getcwd(), 'permission_denied': True}, ensure_ascii=False)
            if scenario != 'empty-answer':
                update('agent_message_chunk', content={'type': 'text', 'text': answer[:11]})
                update('agent_message_chunk', content={'type': 'text', 'text': answer[11:]})
            result = {'stopReason': 'cancelled' if scenario == 'cancelled-answer' else 'end_turn'}
        elif method == 'session/cancel':
            assert 'id' not in request, 'Cancellation must be a notification'
            assert request['params']['sessionId'] == 'test'
            if scenario == 'cancel-ignore':
                continue
            # Permission requests and updates can still arrive during cancellation.
            print(json.dumps({'jsonrpc': '2.0', 'id': 91, 'method': 'session/request_permission',
                              'params': {'sessionId': 'test', 'options': []}}), flush=True)
            permission = json.loads(sys.stdin.readline())
            assert permission['result']['outcome']['outcome'] == 'cancelled'
            update('agent_message_chunk', content={'type': 'text', 'text': ' cancellation acknowledged'})
            print(json.dumps({'jsonrpc': '2.0', 'id': pending_prompt_id,
                              'result': {'stopReason': 'cancelled'}}), flush=True)
            continue
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
