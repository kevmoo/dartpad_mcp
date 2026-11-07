// Copyright (c) 2026, Kevin Moore. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

import '../bin/dartpad_mcp.dart';

final class _BrokenPipeSink implements StringSink {
  const _BrokenPipeSink();

  Never _throwBrokenPipe() {
    throw const FileSystemException(
      'writeFrom failed',
      '',
      OSError('Broken pipe', 32),
    );
  }

  @override
  void write(Object? object) => _throwBrokenPipe();

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _throwBrokenPipe();

  @override
  void writeCharCode(int charCode) => _throwBrokenPipe();

  @override
  void writeln([Object? object = '']) => _throwBrokenPipe();
}

final class _FakeTab {
  _FakeTab(this.socket);

  final WebSocket socket;
  final Completer<String> welcomeSessionId = Completer<String>();
  late final StreamSubscription<Object?> _sub;

  static Future<_FakeTab> connect({
    required int port,
    required String? sessionId,
    required Map<String, FutureOr<Object?> Function(Map<String, Object?>)>
    handlers,
    String? url,
    List<Map<String, Object?>>? customTools,
  }) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/mcp-ws');
    final fake = _FakeTab(ws);
    final tools =
        customTools ??
        <Map<String, Object?>>[
          for (final name in handlers.keys)
            <String, Object?>{
              'name': name,
              'description': 'Tool $name',
              'inputSchema': const <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{},
              },
            },
        ];

    ws.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'webmcp/hello',
        'params': <String, Object?>{
          'sessionId': sessionId,
          'url':
              url ??
              (sessionId == null
                  ? 'https://preview.dartpad.dev/?mcp_port=$port'
                  : 'https://preview.dartpad.dev/?s=$sessionId'),
          'tools': tools,
        },
      }),
    );

    fake._sub = ws.listen((raw) async {
      final msg = jsonDecode(raw as String) as Map<String, Object?>;
      final method = msg['method'];
      if (method == 'webmcp/welcome') {
        final params = msg['params'] as Map<String, Object?>?;
        final assigned = params?['sessionId'];
        if (assigned is String && !fake.welcomeSessionId.isCompleted) {
          fake.welcomeSessionId.complete(assigned);
        }
        return;
      }
      final id = msg['id'];
      if (id == null || method is! String) {
        return;
      }
      if (method == 'tools/list') {
        ws.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, Object?>{'tools': tools},
          }),
        );
        return;
      }
      if (method == 'tools/call') {
        final params = msg['params'] as Map<String, Object?>;
        final name = params['name'] as String;
        final args = Map<String, Object?>.from(
          params['arguments'] as Map? ?? const <String, Object?>{},
        );
        final handler = handlers[name];
        final out = handler == null
            ? <String, Object?>{'unknown': name}
            : await handler(args);
        ws.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, Object?>{
              'content': <Map<String, Object?>>[
                <String, Object?>{'type': 'text', 'text': jsonEncode(out)},
              ],
              'structuredContent': out,
              'isError': false,
            },
          }),
        );
      }
    });
    return fake;
  }

  Future<void> close() async {
    await _sub.cancel();
    await socket.close();
  }
}

Future<void> _waitForConnectedCount(
  DartPadMcpBridge bridge,
  int expected,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    final tabs = bridge.healthSnapshot()['connectedTabs'] as List<Object?>;
    if (tabs.length == expected) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TestFailure('Timed out waiting for $expected connected tabs.');
}

void main() {
  group('parseBridgeCliArgs', () {
    test('parses serve defaults and explicit options', () {
      final defaultCfg = parseBridgeCliArgs(const <String>[]);
      check(defaultCfg.subcommand).equals(BridgeSubcommand.serve);
      check(defaultCfg.port).equals(defaultBridgePort);
      check(defaultCfg.host).equals('localhost');
      check(defaultCfg.stdio).isFalse();

      final custom = parseBridgeCliArgs(const <String>[
        'serve',
        '--port=9123',
        '--host',
        '127.0.0.1',
        '--stdio',
        '--wait-timeout',
        '3.5',
      ]);
      check(custom.port).equals(9123);
      check(custom.host).equals('127.0.0.1');
      check(custom.stdio).isTrue();
      check(custom.waitTimeout).equals(const Duration(milliseconds: 3500));
    });

    test('parses call subcommand with positional and --stdin modes', () {
      final inlineCall = parseBridgeCliArgs(const <String>[
        'call',
        'dartpad_get_status',
        '{"verbose":true}',
        '--port',
        '9001',
        '--session=7',
      ]);
      check(inlineCall.subcommand).equals(BridgeSubcommand.call);
      check(inlineCall.toolName).equals('dartpad_get_status');
      check(inlineCall.rawJsonArgs).equals('{"verbose":true}');
      check(inlineCall.sessionId).equals('7');
      check(
        inlineCall.resolvedMcpUri.toString(),
      ).equals('http://127.0.0.1:9001/mcp');

      final stdinCall = parseBridgeCliArgs(const <String>[
        'call',
        '--stdin',
        '--',
        'dartpad_write_files',
      ]);
      check(stdinCall.useStdinArgs).isTrue();
      check(stdinCall.toolName).equals('dartpad_write_files');
      check(stdinCall.rawJsonArgs).isNull();
    });

    test('rejects unknown flags and invalid values with CliUsageException', () {
      for (final badArgs in const <List<String>>[
        <String>['--bogus'],
        <String>['--port', '99999'],
        <String>['--port'],
        <String>['--wait-timeout', '-1'],
        <String>['unknown-cmd'],
        <String>['call'],
        <String>['call', 'tool', '{}', '--stdin'],
      ]) {
        check(() => parseBridgeCliArgs(badArgs)).throws<CliUsageException>();
      }
    });
  });

  group('DartPadMcpBridge HTTP & WebSocket hub', () {
    test(
      'serves healthz, CORS preflight, and Streamable HTTP edge cases',
      () async {
        final bridge = await DartPadMcpBridge.start(
          port: 0,
          waitTimeout: const Duration(milliseconds: 100),
        );
        addTearDown(bridge.close);

        final healthUri = Uri.parse('http://127.0.0.1:${bridge.port}/healthz');
        final mcpUri = Uri.parse('http://127.0.0.1:${bridge.port}/mcp');
        final health = await fetchBridgeHealth(healthUri);
        check(health).isNotNull();
        check(health!['port']).equals(bridge.port);

        final client = HttpClient()..findProxy = (_) => 'DIRECT';
        addTearDown(() => client.close(force: true));

        final optionsReq = await client.openUrl('OPTIONS', mcpUri);
        final optionsResp = await optionsReq.close();
        await optionsResp.drain<void>();
        check(optionsResp.statusCode).equals(HttpStatus.noContent);
        check(
          optionsResp.headers.value('Access-Control-Allow-Private-Network'),
        ).equals('true');

        final getMcp = await (await client.getUrl(mcpUri)).close();
        await getMcp.drain<void>();
        check(getMcp.statusCode).equals(HttpStatus.methodNotAllowed);

        final delMcp = await (await client.deleteUrl(mcpUri)).close();
        await delMcp.drain<void>();
        check(delMcp.statusCode).equals(HttpStatus.ok);

        final badPost = await client.postUrl(mcpUri);
        badPost.add(utf8.encode('{broken-json'));
        final badResp = await badPost.close();
        final badBody = jsonDecode(await utf8.decoder.bind(badResp).join());
        check(badResp.statusCode).equals(HttpStatus.badRequest);
        check((badBody as Map<String, Object?>)['error']).isNotNull();
      },
    );

    test(
      'waits for cold-start tab, routes multi-tab sessionId, and caches tools',
      () async {
        final bridge = await DartPadMcpBridge.start(
          port: 0,
          waitTimeout: const Duration(seconds: 3),
        );
        addTearDown(bridge.close);
        final mcpUri = Uri.parse('http://127.0.0.1:${bridge.port}/mcp');

        final initResp =
            await postMcpHttp(mcpUri, const <String, Object?>{
                  'jsonrpc': '2.0',
                  'id': 1,
                  'method': 'initialize',
                  'params': <String, Object?>{'protocolVersion': '2025-06-18'},
                })
                as Map<String, Object?>;
        final initResult = initResp['result'] as Map<String, Object?>;
        check(initResult['protocolVersion']).equals('2025-06-18');

        final notifResp = await postMcpHttp(mcpUri, const <String, Object?>{
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        });
        check(notifResp).isNull();

        // Start a tool call BEFORE any browser tab has connected.
        final coldCallFuture = postMcpHttp(mcpUri, const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'dartpad_get_status',
            'arguments': <String, Object?>{},
          },
        });

        final tab1 = await _FakeTab.connect(
          port: bridge.port,
          sessionId: '1',
          handlers: <String, FutureOr<Object?> Function(Map<String, Object?>)>{
            'dartpad_get_status': (args) => <String, Object?>{
              'tab': '1',
              'receivedSessionKey': args.containsKey('sessionId'),
            },
          },
        );
        addTearDown(tab1.close);

        final coldResp = (await coldCallFuture) as Map<String, Object?>;
        final coldResult = coldResp['result'] as Map<String, Object?>;
        final coldData =
            coldResult['structuredContent'] as Map<String, Object?>;
        check(coldData['tab']).equals('1');
        check(coldData['receivedSessionKey']).equals(false);

        // Connect a second tab (`s=2`) and verify multi-tab session routing.
        final tab2 = await _FakeTab.connect(
          port: bridge.port,
          sessionId: '2',
          handlers: <String, FutureOr<Object?> Function(Map<String, Object?>)>{
            'dartpad_get_status': (args) => <String, Object?>{'tab': '2'},
          },
        );
        addTearDown(tab2.close);
        await _waitForConnectedCount(bridge, 2);

        // Default routes to most recently active tab (`2`).
        final defaultCall =
            await postMcpHttp(mcpUri, const <String, Object?>{
                  'jsonrpc': '2.0',
                  'id': 3,
                  'method': 'tools/call',
                  'params': <String, Object?>{'name': 'dartpad_get_status'},
                })
                as Map<String, Object?>;
        check(
          ((defaultCall['result'] as Map<String, Object?>)['structuredContent']
              as Map<String, Object?>)['tab'],
        ).equals('2');

        // Explicit `sessionId: "1"` routes to tab 1 WITHOUT flipping the
        // untargeted active default away from tab 2.
        final targetedCall =
            await postMcpHttp(mcpUri, const <String, Object?>{
                  'jsonrpc': '2.0',
                  'id': 4,
                  'method': 'tools/call',
                  'params': <String, Object?>{
                    'name': 'dartpad_get_status',
                    'arguments': <String, Object?>{'sessionId': '1'},
                  },
                })
                as Map<String, Object?>;
        check(
          ((targetedCall['result'] as Map<String, Object?>)['structuredContent']
              as Map<String, Object?>)['tab'],
        ).equals('1');

        final defaultAfterTargeted =
            await postMcpHttp(mcpUri, const <String, Object?>{
                  'jsonrpc': '2.0',
                  'id': 41,
                  'method': 'tools/call',
                  'params': <String, Object?>{'name': 'dartpad_get_status'},
                })
                as Map<String, Object?>;
        check(
          ((defaultAfterTargeted['result']
                  as Map<String, Object?>)['structuredContent']
              as Map<String, Object?>)['tab'],
        ).equals('2');

        // A tab connecting without `?s=` receives its assigned `tab-<connId>`
        // via `webmcp/welcome`.
        final bareTab = await _FakeTab.connect(
          port: bridge.port,
          sessionId: null,
          handlers: <String, FutureOr<Object?> Function(Map<String, Object?>)>{
            'dartpad_get_status': (args) => <String, Object?>{'tab': 'bare'},
          },
        );
        addTearDown(bareTab.close);
        final welcomedSid = await bareTab.welcomeSessionId.future.timeout(
          const Duration(seconds: 2),
        );
        check(welcomedSid).equals('tab-3');

        // Close all tabs and confirm `tools/list` still serves cached schemas.
        await tab1.close();
        await tab2.close();
        await bareTab.close();
        await _waitForConnectedCount(bridge, 0);

        final cachedList =
            await postMcpHttp(mcpUri, const <String, Object?>{
                  'jsonrpc': '2.0',
                  'id': 5,
                  'method': 'tools/list',
                })
                as Map<String, Object?>;
        final tools =
            (cachedList['result'] as Map<String, Object?>)['tools']
                as List<Object?>;
        check(tools).isNotEmpty();
      },
    );
  });

  group('runDartPadMcpCli & standalone script execution', () {
    test(
      'executes status, tools, call --stdin, and stdio auto-attach',
      () async {
        final bridge = await DartPadMcpBridge.start(port: 0);
        addTearDown(bridge.close);

        final outEmpty = StringBuffer();
        final errEmpty = StringBuffer();
        final requireTabCode = await runDartPadMcpCli(
          <String>['status', '--port', '${bridge.port}', '--require-tab'],
          out: outEmpty,
          err: errEmpty,
        );
        check(requireTabCode).equals(2);

        final tab = await _FakeTab.connect(
          port: bridge.port,
          sessionId: '3',
          handlers: <String, FutureOr<Object?> Function(Map<String, Object?>)>{
            'dartpad_write_files': (args) => <String, Object?>{
              'echo': args['note'],
            },
          },
        );
        addTearDown(tab.close);
        await _waitForConnectedCount(bridge, 1);

        final statusOut = StringBuffer();
        final statusCode = await runDartPadMcpCli(
          <String>['status', '--port', '${bridge.port}', '--require-tab'],
          out: statusOut,
          err: StringBuffer(),
        );
        check(statusCode).equals(0);

        final callOut = StringBuffer();
        final callCode = await runDartPadMcpCli(
          <String>[
            'call',
            'dartpad_write_files',
            '--stdin',
            '--port',
            '${bridge.port}',
          ],
          input: Stream<List<int>>.value(
            utf8.encode('{"note":"Hello € from stdin"}'),
          ),
          out: callOut,
          err: StringBuffer(),
        );
        check(callCode).equals(0);
        final callJson = jsonDecode(callOut.toString()) as Map<String, Object?>;
        check(callJson['echo']).equals('Hello € from stdin');

        // `--stdio` on an already-bound port auto-attaches to `/mcp`.
        final stdioReq = jsonEncode(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 99,
          'method': 'tools/list',
        });
        final reqBytes = utf8.encode(stdioReq);
        final framed = <int>[
          ...utf8.encode('Content-Length: ${reqBytes.length}\r\n\r\n'),
          ...reqBytes,
        ];
        final stdioOut = StringBuffer();
        final stdioErr = StringBuffer();
        final stdioCode = await runDartPadMcpCli(
          <String>['--stdio', '--port', '${bridge.port}'],
          input: Stream<List<int>>.value(framed),
          out: stdioOut,
          err: stdioErr,
        );
        check(stdioCode).equals(0);
        check(stdioErr.toString()).contains('Forwarding stdio MCP');
        final stdioResp =
            jsonDecode(stdioOut.toString().trim()) as Map<String, Object?>;
        check(stdioResp['id']).equals(99);

        // Broken consumer pipes (`EPIPE`, errno 32) exit 0 cleanly instead of
        // crashing with an unhandled FileSystemException.
        for (final cliArgs in <List<String>>[
          <String>['--help'],
          <String>['status', '--port', '${bridge.port}'],
          <String>[
            'call',
            'dartpad_write_files',
            '{"note":"epipe"}',
            '--port',
            '${bridge.port}',
          ],
        ]) {
          final epipeCode = await runDartPadMcpCli(
            cliArgs,
            out: const _BrokenPipeSink(),
            err: StringBuffer(),
          );
          check(epipeCode).equals(0);
        }
      },
    );

    test(
      'runs bin/dartpad_mcp.dart outside any package with zero pub deps',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'dartpad_mcp_solo_',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));

        final scriptSource = File('bin/dartpad_mcp.dart');
        final isolatedScript = File('${tempDir.path}/dartpad_mcp.dart');
        scriptSource.copySync(isolatedScript.path);

        final result = await Process.run(Platform.resolvedExecutable, <String>[
          isolatedScript.path,
          '--help',
        ], workingDirectory: tempDir.path);
        check(result.exitCode).equals(0);
        check('${result.stdout}').contains('dartpad_mcp call');

        // Real OS broken-pipe (`EPIPE` on `dart:io` `stdout`) exits 0 cleanly
        // when a downstream pipe consumer (`jq`, `head`) closes stdout early.
        final proc = await Process.start(Platform.resolvedExecutable, <String>[
          isolatedScript.path,
          '--help',
        ], workingDirectory: tempDir.path);
        await proc.stdout.listen((_) {}).cancel();
        final stderrText = await utf8.decoder.bind(proc.stderr).join();
        final pipedExit = await proc.exitCode;
        check(pipedExit).equals(0);
        check(stderrText).not((it) => it.contains('FileSystemException'));
      },
    );
  });
}
