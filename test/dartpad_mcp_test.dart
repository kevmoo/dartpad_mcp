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

final class _LineNotificationSink implements StringSink {
  _LineNotificationSink(this._lines);

  final StreamController<String> _lines;
  final StringBuffer _pending = StringBuffer();

  @override
  void write(Object? object) {
    _pending.write(object);
    _flushLines();
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _pending.writeAll(objects, separator);
    _flushLines();
  }

  @override
  void writeCharCode(int charCode) {
    _pending.writeCharCode(charCode);
    _flushLines();
  }

  @override
  void writeln([Object? object = '']) {
    _pending.writeln(object);
    _flushLines();
  }

  void _flushLines() {
    final full = _pending.toString();
    final parts = full.split('\n');
    if (parts.length <= 1) {
      return;
    }
    for (var i = 0; i < parts.length - 1; i++) {
      final line = parts[i].trim();
      if (line.isNotEmpty && !_lines.isClosed) {
        _lines.add(line);
      }
    }
    _pending
      ..clear()
      ..write(parts.last);
  }
}

final class _FakeTab {
  _FakeTab(this.socket, this._tools);

  final WebSocket socket;
  final List<Map<String, Object?>> _tools;
  final Completer<String> welcomeSessionId = Completer<String>();
  late final StreamSubscription<Object?> _sub;

  void sendHello({String? sessionId, String? clientTabId, String? url}) {
    socket.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'webmcp/hello',
        'params': <String, Object?>{
          'sessionId': sessionId,
          'clientTabId': ?clientTabId,
          'url':
              url ??
              (sessionId == null
                  ? 'https://preview.dartpad.dev/'
                  : 'https://preview.dartpad.dev/?s=$sessionId'),
          'tools': _tools,
        },
      }),
    );
  }

  static Future<_FakeTab> connect({
    required int port,
    required String? sessionId,
    required Map<String, FutureOr<Object?> Function(Map<String, Object?>)>
    handlers,
    String? clientTabId,
    String? url,
    List<Map<String, Object?>>? customTools,
  }) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/mcp-ws');
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
    final fake = _FakeTab(ws, tools)
      ..sendHello(
        sessionId: sessionId,
        clientTabId: clientTabId,
        url:
            url ??
            (sessionId == null
                ? 'https://preview.dartpad.dev/?mcp_port=$port'
                : 'https://preview.dartpad.dev/?s=$sessionId'),
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
      check(defaultCfg.detach).isFalse();
      check(defaultCfg.stdio).isFalse();

      final detachedCfg = parseBridgeCliArgs(const <String>[
        '--detach',
        '--port=0',
      ]);
      check(detachedCfg.detach).isTrue();
      check(detachedCfg.port).equals(0);

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
        <String>['--detach', '--stdio'],
        <String>['status', '--detach'],
      ]) {
        check(() => parseBridgeCliArgs(badArgs)).throws<CliUsageException>();
      }
    });

    test('resolveSelfInvocation distinguishes AOT binaries from Dart VM', () {
      final aotUnix = resolveSelfInvocation(
        resolvedExecutable: '/opt/dart/app-bundles/dartpad_mcp/bin/dartpad_mcp',
        scriptUri: Uri.file('/tmp/ignored.dart'),
      );
      check(
        aotUnix.executable,
      ).equals('/opt/dart/app-bundles/dartpad_mcp/bin/dartpad_mcp');
      check(aotUnix.prefixArgs).isEmpty();

      final aotWin = resolveSelfInvocation(
        resolvedExecutable: r'C:\Users\dev\Dart\install\bin\dartpad_mcp.exe',
        scriptUri: Uri.file('/tmp/ignored.dart'),
      );
      check(
        aotWin.executable,
      ).equals(r'C:\Users\dev\Dart\install\bin\dartpad_mcp.exe');
      check(aotWin.prefixArgs).isEmpty();

      final jitScript = resolveSelfInvocation(
        resolvedExecutable: '/sdk/bin/dart',
        scriptUri: Uri.file('/tmp/dartpad_mcp.dart'),
      );
      check(jitScript.executable).equals('/sdk/bin/dart');
      check(
        jitScript.prefixArgs,
      ).deepEquals(const <String>['/tmp/dartpad_mcp.dart']);
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
        final capabilities = initResult['capabilities'] as Map<String, Object?>;
        check(
          (capabilities['tools'] as Map<String, Object?>)['listChanged'],
        ).equals(true);

        // Cold unscoped `tools/list` returns the 9 baseline DartPad tools
        // immediately without blocking for `waitTimeout` (3s).
        final coldToolsSw = Stopwatch()..start();
        final coldToolsResp =
            await postMcpHttp(mcpUri, const <String, Object?>{
                  'jsonrpc': '2.0',
                  'id': 10,
                  'method': 'tools/list',
                })
                as Map<String, Object?>;
        coldToolsSw.stop();
        check(coldToolsSw.elapsedMilliseconds).isLessThan(1000);
        final coldTools =
            (coldToolsResp['result'] as Map<String, Object?>)['tools']
                as List<Object?>;
        check(coldTools.length).equals(9);

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

    test(
      'evicts superseded clientTabId sockets on reconnect and pings dead peers',
      () async {
        final bridge = await DartPadMcpBridge.start(
          port: 0,
          pingInterval: const Duration(milliseconds: 60),
        );
        addTearDown(bridge.close);

        // Connect initial socket for `tab-same`, then open a replacement socket
        // with the same `clientTabId` without closing the old one first
        // (simulating a half-open SSH tunnel reconnect or browser reload).
        final staleTab = await _FakeTab.connect(
          port: bridge.port,
          sessionId: '1',
          clientTabId: 'tab-same',
          handlers: <String, FutureOr<Object?> Function(Map<String, Object?>)>{
            'dartpad_get_status': (_) => <String, Object?>{'gen': 'stale'},
          },
        );
        addTearDown(staleTab.close);
        await _waitForConnectedCount(bridge, 1);

        final freshTab = await _FakeTab.connect(
          port: bridge.port,
          sessionId: '1',
          clientTabId: 'tab-same',
          handlers: <String, FutureOr<Object?> Function(Map<String, Object?>)>{
            'dartpad_get_status': (_) => <String, Object?>{'gen': 'fresh'},
          },
        );
        addTearDown(freshTab.close);

        // Wait for `freshTab`'s `webmcp/hello` to evict `staleTab`, while a
        // genuinely distinct browser tab (`tab-other`) sharing `s=1` coexists.
        final distinctTab = await _FakeTab.connect(
          port: bridge.port,
          sessionId: '1',
          clientTabId: 'tab-other',
          handlers: <String, FutureOr<Object?> Function(Map<String, Object?>)>{
            'dartpad_get_status': (_) => <String, Object?>{'gen': 'distinct'},
          },
        );
        addTearDown(distinctTab.close);
        await _waitForConnectedCount(bridge, 2);

        final tabs = (bridge.healthSnapshot()['connectedTabs'] as List<Object?>)
            .cast<Map<String, Object?>>();
        final clientIds = <String>[
          for (final entry in tabs) '${entry['clientTabId']}',
        ];
        check(
          clientIds,
        ).unorderedEquals(const <String>['tab-same', 'tab-other']);

        // Open a raw TCP socket that completes the HTTP->WebSocket handshake
        // and sends `webmcp/hello`, then drops all incoming RFC 6455 Ping
        // frames without replying Pong (simulating a dead SSH tunnel).
        final rawSocket = await Socket.connect('127.0.0.1', bridge.port);
        addTearDown(rawSocket.destroy);
        rawSocket.add(
          utf8.encode(
            'GET /mcp-ws HTTP/1.1\r\n'
            'Host: 127.0.0.1:${bridge.port}\r\n'
            'Upgrade: websocket\r\n'
            'Connection: Upgrade\r\n'
            'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
            'Sec-WebSocket-Version: 13\r\n\r\n',
          ),
        );
        // Drain bytes silently without replying to WebSocket Ping frames.
        final rawSub = rawSocket.listen((_) {});
        addTearDown(rawSub.cancel);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Send a masked client text frame announcing `webmcp/hello`.
        final helloBytes = utf8.encode(
          jsonEncode(const <String, Object?>{
            'jsonrpc': '2.0',
            'method': 'webmcp/hello',
            'params': <String, Object?>{
              'sessionId': 'zombie',
              'clientTabId': 'tab-dead',
              'url': 'https://preview.dartpad.dev/?s=zombie',
              'tools': <Object?>[],
            },
          }),
        );
        final header = <int>[
          0x81,
          if (helloBytes.length < 126)
            0x80 | helloBytes.length
          else ...<int>[
            0x80 | 126,
            (helloBytes.length >> 8) & 0xFF,
            helloBytes.length & 0xFF,
          ],
          0,
          0,
          0,
          0,
          ...helloBytes,
        ];
        rawSocket.add(header);
        await _waitForConnectedCount(bridge, 3);

        // Because `rawSocket` never replies with Pong, `pingInterval` (60ms)
        // automatically closes and evicts `tab-dead` back down to 2 tabs.
        await _waitForConnectedCount(bridge, 2);
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

        // `--require-tab --session <missing>` exits 2 even while session `3`
        // is connected, whereas `--session 3` exits 0 with matchedSession=true.
        final unmatchedStatusOut = StringBuffer();
        final unmatchedStatusErr = StringBuffer();
        final unmatchedCode = await runDartPadMcpCli(
          <String>[
            'status',
            '--port',
            '${bridge.port}',
            '--require-tab',
            '--session',
            'tab-missing',
          ],
          out: unmatchedStatusOut,
          err: unmatchedStatusErr,
        );
        check(unmatchedCode).equals(2);
        check(unmatchedStatusErr.toString()).contains('tab-missing');
        check(unmatchedStatusErr.toString()).contains('connected sessions: 3');
        final unmatchedJson =
            jsonDecode(unmatchedStatusOut.toString()) as Map<String, Object?>;
        check(unmatchedJson['matchedSession']).equals(false);

        final matchedStatusOut = StringBuffer();
        final matchedCode = await runDartPadMcpCli(
          <String>[
            'status',
            '--port',
            '${bridge.port}',
            '--require-tab',
            '--session',
            '3',
          ],
          out: matchedStatusOut,
          err: StringBuffer(),
        );
        check(matchedCode).equals(0);
        final matchedJson =
            jsonDecode(matchedStatusOut.toString()) as Map<String, Object?>;
        check(matchedJson['matchedSession']).equals(true);

        // `tools --session <missing>` fails non-zero instead of returning
        // cached tools from another tab.
        final missingToolsErr = StringBuffer();
        final missingToolsCode = await runDartPadMcpCli(
          <String>[
            'tools',
            '--port',
            '${bridge.port}',
            '--session',
            'tab-missing',
            '--wait-timeout',
            '0.05',
          ],
          out: StringBuffer(),
          err: missingToolsErr,
        );
        check(missingToolsCode).equals(1);
        check(missingToolsErr.toString()).contains('sessionId=tab-missing');

        // A bare tab with `clientTabId: "tab-k7m2"` remains addressable by
        // BOTH `--session tab-k7m2` AND `--session 4` after persistence mints
        // `?s=4` and re-announces `webmcp/hello`.
        final aliasedTab = await _FakeTab.connect(
          port: bridge.port,
          sessionId: 'tab-k7m2',
          clientTabId: 'tab-k7m2',
          handlers: <String, FutureOr<Object?> Function(Map<String, Object?>)>{
            'dartpad_write_files': (args) => <String, Object?>{
              'echo': 'aliased:${args['note']}',
            },
          },
        );
        addTearDown(aliasedTab.close);
        await _waitForConnectedCount(bridge, 2);

        aliasedTab.sendHello(
          sessionId: '4',
          clientTabId: 'tab-k7m2',
          url: 'https://preview.dartpad.dev/?s=4',
        );
        // Wait for the updated `sessionId == '4'` to land on the bridge.
        final aliasDeadline = DateTime.now().add(const Duration(seconds: 2));
        while (DateTime.now().isBefore(aliasDeadline)) {
          final tabs =
              bridge.healthSnapshot()['connectedTabs'] as List<Object?>;
          final updated = tabs.whereType<Map<String, Object?>>().any(
            (entry) =>
                entry['sessionId'] == '4' && entry['clientTabId'] == 'tab-k7m2',
          );
          if (updated) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        final aliasStatusCode = await runDartPadMcpCli(
          <String>[
            'status',
            '--port',
            '${bridge.port}',
            '--require-tab',
            '--session',
            'tab-k7m2',
          ],
          out: StringBuffer(),
          err: StringBuffer(),
        );
        check(aliasStatusCode).equals(0);

        for (final targetSid in const <String>['tab-k7m2', '4']) {
          final aliasCallOut = StringBuffer();
          final aliasCallCode = await runDartPadMcpCli(
            <String>[
              'call',
              'dartpad_write_files',
              '{"note":"via-$targetSid"}',
              '--port',
              '${bridge.port}',
              '--session',
              targetSid,
            ],
            out: aliasCallOut,
            err: StringBuffer(),
          );
          check(aliasCallCode).equals(0);
          final aliasJson =
              jsonDecode(aliasCallOut.toString()) as Map<String, Object?>;
          check(aliasJson['echo']).equals('aliased:via-$targetSid');
        }
        await aliasedTab.close();
        await _waitForConnectedCount(bridge, 1);

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

    test('emits notifications/tools/list_changed on --stdio and fails over if '
        'prior port owner exits', () async {
      // 1. Direct `--stdio` mode: emits `notifications/tools/list_changed`
      // after `initialize` when a tab connects with updated tool schemas.
      final directPortFile = File(
        '${Directory.systemTemp.createTempSync('stdio_direct_').path}/port',
      );
      addTearDown(() => directPortFile.parent.deleteSync(recursive: true));

      final directIn = StreamController<List<int>>();
      addTearDown(directIn.close);
      final directLines = StreamController<String>();
      addTearDown(directLines.close);
      final directOut = _LineNotificationSink(directLines);

      final directFuture = runDartPadMcpCli(
        <String>['--stdio', '--port', '0', '--port-file', directPortFile.path],
        input: directIn.stream,
        out: directOut,
        err: StringBuffer(),
      );

      final deadline = DateTime.now().add(const Duration(seconds: 3));
      var boundPort = 0;
      while (DateTime.now().isBefore(deadline)) {
        if (directPortFile.existsSync()) {
          boundPort =
              int.tryParse(directPortFile.readAsStringSync().trim()) ?? 0;
          if (boundPort > 0) {
            break;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      check(boundPort).isGreaterThan(0);

      final lineIter = StreamIterator<String>(directLines.stream);
      addTearDown(lineIter.cancel);

      directIn.add(
        utf8.encode(
          '${jsonEncode(const <String, Object?>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': <String, Object?>{'protocolVersion': '2025-06-18'},
          })}\n',
        ),
      );
      check(
        await lineIter.moveNext().timeout(const Duration(seconds: 2)),
      ).isTrue();
      final initMsg = jsonDecode(lineIter.current) as Map<String, Object?>;
      check(initMsg['id']).equals(1);

      final customTab = await _FakeTab.connect(
        port: boundPort,
        sessionId: '1',
        handlers: <String, FutureOr<Object?> Function(Map<String, Object?>)>{
          'experimental_custom_tool': (_) => const <String, Object?>{},
        },
      );
      addTearDown(customTab.close);

      check(
        await lineIter.moveNext().timeout(const Duration(seconds: 2)),
      ).isTrue();
      final listChangedMsg =
          jsonDecode(lineIter.current) as Map<String, Object?>;
      check(
        listChangedMsg['method'],
      ).equals('notifications/tools/list_changed');

      await customTab.close();
      await directIn.close();
      check(await directFuture).equals(0);

      // 2. Proxy `--stdio` failover mode: start primary bridge on a dedicated
      // port, attach `--stdio`, close the primary bridge, and verify `--stdio`
      // seamlessly re-binds the port on the next request.
      final primary = await DartPadMcpBridge.start(port: 0);
      final sharedPort = primary.port;
      addTearDown(primary.close);

      final failoverIn = StreamController<List<int>>();
      addTearDown(failoverIn.close);
      final failoverLines = StreamController<String>();
      addTearDown(failoverLines.close);
      final failoverErr = StringBuffer();

      final failoverFuture = runDartPadMcpCli(
        <String>['--stdio', '--port', '$sharedPort'],
        input: failoverIn.stream,
        out: _LineNotificationSink(failoverLines),
        err: failoverErr,
      );
      final failoverIter = StreamIterator<String>(failoverLines.stream);
      addTearDown(failoverIter.cancel);

      // Wait until `init()` logs proxy attachment before sending first ping.
      final attachDeadline = DateTime.now().add(const Duration(seconds: 3));
      while (!failoverErr.toString().contains('Forwarding stdio MCP') &&
          DateTime.now().isBefore(attachDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      check(failoverErr.toString()).contains('Forwarding stdio MCP');

      final pingFrame = jsonEncode(const <String, Object?>{
        'jsonrpc': '2.0',
        'id': 10,
        'method': 'ping',
      });
      failoverIn.add(utf8.encode('$pingFrame\n'));
      check(
        await failoverIter.moveNext().timeout(const Duration(seconds: 2)),
      ).isTrue();
      check(
        (jsonDecode(failoverIter.current) as Map<String, Object?>)['id'],
      ).equals(10);

      // Kill the primary owner of `sharedPort` and send `tools/list`.
      await primary.close();
      final toolsFrame = jsonEncode(const <String, Object?>{
        'jsonrpc': '2.0',
        'id': 11,
        'method': 'tools/list',
      });
      failoverIn.add(utf8.encode('$toolsFrame\n'));
      check(
        await failoverIter.moveNext().timeout(const Duration(seconds: 3)),
      ).isTrue();
      final postFailover =
          jsonDecode(failoverIter.current) as Map<String, Object?>;
      check(postFailover['id']).equals(11);
      check(
        ((postFailover['result'] as Map<String, Object?>)['tools']
                as List<Object?>)
            .length,
      ).equals(9);
      check(failoverErr.toString()).contains('re-binding port $sharedPort');

      await failoverIn.close();
      check(await failoverFuture).equals(0);
    });

    test(
      '--detach spawns background bridge, prints JSON info, and reuses active '
      'port idempotently',
      () async {
        final firstOut = StringBuffer();
        final firstCode = await runDartPadMcpCli(
          const <String>['--detach', '--port', '0'],
          out: firstOut,
          err: StringBuffer(),
        );
        check(firstCode).equals(0);
        final firstJson =
            jsonDecode(firstOut.toString()) as Map<String, Object?>;
        final spawnedPid = firstJson['pid'] as int;
        final spawnedPort = firstJson['port'] as int;
        addTearDown(() {
          Process.killPid(spawnedPid);
        });
        check(firstJson['ok']).equals(true);
        check(firstJson['reused']).equals(false);
        check(spawnedPort).isGreaterThan(0);
        check(firstJson['executable'] as String).isNotEmpty();

        // Re-running `--detach` on the same port succeeds idempotently with
        // `reused: true` without spawning a second daemon.
        final secondOut = StringBuffer();
        final secondCode = await runDartPadMcpCli(
          <String>['--detach', '--port', '$spawnedPort'],
          out: secondOut,
          err: StringBuffer(),
        );
        check(secondCode).equals(0);
        final secondJson =
            jsonDecode(secondOut.toString()) as Map<String, Object?>;
        check(secondJson['ok']).equals(true);
        check(secondJson['reused']).equals(true);
        check(secondJson['port']).equals(spawnedPort);
        check(secondJson['pid']).equals(spawnedPid);
      },
    );
  });
}
