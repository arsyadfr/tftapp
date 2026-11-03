// lib/main.dart
//
// Setup:
//   flutter pub add flutter_blue_plus http
//
// BLE protocol (matches ESP32-C3 firmware):
//   0x01 + uint32 LE length  -> image START
//   0x02 + bytes             -> image DATA
//   0x03                     -> image END
//   0x04 + "title\nartist"   -> metadata
//
// Uses acknowledged BLE writes to avoid dropping image packets.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;

final Guid kService = Guid('12345678-1234-1234-1234-1234567890ab');
final Guid kChar = Guid('12345678-1234-1234-1234-1234567890ac');

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Home(),
  ));
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  static const MethodChannel _method = MethodChannel('nowplaying/method');
  static const EventChannel _events = EventChannel('nowplaying/events');

  final TextEditingController _titleCtl = TextEditingController();
  final TextEditingController _artistCtl = TextEditingController();

  BluetoothDevice? _dev;
  BluetoothCharacteristic? _char;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<dynamic>? _npSub;

  bool _connecting = false;
  bool _sending = false;
  bool _disposed = false;
  Timer? _pollTimer;   // fallback poll for the current song (background)

  // All GATT writes are serialized. This prevents two metadata/artwork
  // transfers from writing to the same characteristic simultaneously.
  Future<void> _bleQueue = Future<void>.value();

  Uint8List? _lastJpg;
  String _lastTitle = '';
  String _lastArtist = '';
  String _status = 'Starting...';
  String _nowPlaying = '-';

  // Incremented for every track change. An older artwork HTTP response
  // is discarded if a newer track has arrived.
  int _trackGeneration = 0;
  String _lastKey = '';

  @override
  void initState() {
    super.initState();
    _scan();
    if (Platform.isIOS) {
      _startNowPlaying();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _scanSub?.cancel();
    _connSub?.cancel();
    _npSub?.cancel();
    _pollTimer?.cancel();
    _titleCtl.dispose();
    _artistCtl.dispose();
    super.dispose();
  }

  void _setStatus(String value) {
    if (!_disposed && mounted) {
      setState(() => _status = value);
    }
  }

  void _setNowPlaying(String value) {
    if (!_disposed && mounted) {
      setState(() => _nowPlaying = value);
    }
  }

  Future<void> _retryScan() async {
    if (_disposed) return;
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!_disposed && _dev == null && !_connecting) {
      _scan();
    }
  }

  // ---------------------------------------------------------------------------
  // BLE scan / connection
  // ---------------------------------------------------------------------------

  Future<void> _scan() async {
    if (_disposed || _connecting || _dev != null) return;

    _connecting = true;
    _setStatus('Waiting for Bluetooth...');

    try {
      await FlutterBluePlus.adapterState
          .where((state) => state == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 20));

      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        if (_disposed || _dev != null || results.isEmpty) return;

        for (final result in results) {
          if (result.device.remoteId.str.isEmpty) continue;

          // The service filter is also applied by startScan. Take the
          // first matching result and stop scanning before connecting.
          _dev = result.device;
          FlutterBluePlus.stopScan();
          _scanSub?.cancel();
          _connect(result.device);
          break;
        }
      });

      _setStatus('Scanning for ESP-Art...');
      await FlutterBluePlus.startScan(
        withServices: [kService],
        timeout: const Duration(seconds: 15),
      );

      // startScan returns after its timeout. If nothing was found, retry.
      if (_dev == null && !_disposed) {
        await _scanSub?.cancel();
        _connecting = false;
        _setStatus('ESP-Art not found. Retrying...');
        _retryScan();
      }
    } catch (e) {
      if (!_disposed) {
        _setStatus('Scan error: $e');
        _dev = null;
        _connecting = false;
        _retryScan();
      }
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    try {
      _setStatus('Connecting to ESP-Art...');

      // FlutterBluePlus 2.x: connect() without the old autoConnect argument.
      await device.connect(
  license: License.nonprofit,
);

      if (Platform.isAndroid) {
        try {
          await device.requestMtu(512);
        } catch (_) {
          // Keep the negotiated MTU if the request is unsupported.
        }
      }

      final services = await device.discoverServices();
      BluetoothCharacteristic? found;

      for (final service in services) {
        if (service.uuid == kService) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid == kChar) {
              found = characteristic;
              break;
            }
          }
        }
      }

      if (found == null) {
        throw Exception('BLE characteristic not found');
      }

      _char = found;

      await _connSub?.cancel();
      _connSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _char = null;
          _dev = null;
          _connecting = false;
          _setStatus('Disconnected. Reconnecting...');
          _retryScan();
        }
      });

      _connecting = false;
      _setStatus('Connected to ESP-Art');

      // Restore the most recent track after reconnecting.
      if (_lastTitle.isNotEmpty) {
        await _sendMeta(_lastTitle, _lastArtist);
      }
      final jpg = _lastJpg;
      if (jpg != null) {
        await _sendJpeg(jpg);
      }
    } catch (e) {
      _setStatus('Connect error: $e');
      _char = null;
      _dev = null;
      _connecting = false;
      try {
        await device.disconnect();
      } catch (_) {}
      _retryScan();
    }
  }

  // Queue a BLE operation so that metadata and image transfers never overlap.
  Future<void> _enqueueBle(Future<void> Function() operation) {
    final next = _bleQueue.then((_) => operation());
    _bleQueue = next.catchError((Object error) {
      _setStatus('BLE queue error: $error');
    });
    return next;
  }

  Future<void> _sendJpeg(Uint8List jpg) {
    return _enqueueBle(() async {
      final characteristic = _char;
      final device = _dev;

      if (characteristic == null || device == null) {
        _setStatus('Artwork ready; waiting for ESP-Art connection');
        return;
      }
      if (jpg.isEmpty) {
        _setStatus('Artwork is empty');
        return;
      }

      _sending = true;
      try {
        _setStatus('Sending artwork (${jpg.length} bytes)...');

        // ATT write payload is MTU - 3. One byte is used by our packet type.
        // Do not force a minimum of 20: at the default MTU 23, JPEG data
        // must be 19 bytes so the full packet stays within the ATT limit.
        final int chunkSize = (device.mtuNow - 4).clamp(1, 509);

        final header = ByteData(5)
          ..setUint8(0, 0x01)
          ..setUint32(1, jpg.length, Endian.little);

        // Acknowledged writes: wait for each packet before sending the next.
        await characteristic.write(
          header.buffer.asUint8List(),
          withoutResponse: false,
        );

        for (int offset = 0; offset < jpg.length; offset += chunkSize) {
          if (_char != characteristic || _dev != device) {
            throw Exception('BLE disconnected during artwork transfer');
          }

          final int end =
              (offset + chunkSize < jpg.length) ? offset + chunkSize : jpg.length;

          final packet = <int>[
            0x02,
            ...jpg.sublist(offset, end),
          ];

          await characteristic.write(
            packet,
            withoutResponse: false,
          );
        }

        if (_char != characteristic || _dev != device) {
          throw Exception('BLE disconnected before artwork END packet');
        }

        await characteristic.write(
          [0x03],
          withoutResponse: false,
        );

        _setStatus('Artwork sent successfully');
      } catch (e) {
        _setStatus('Artwork send error: $e');
      } finally {
        _sending = false;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Metadata
  // ---------------------------------------------------------------------------

  static const Map<String, String> _accents = {
    'àáâãäåā': 'a',
    'ÀÁÂÃÄÅĀ': 'A',
    'èéêëē': 'e',
    'ÈÉÊËĒ': 'E',
    'ìíîïī': 'i',
    'ÌÍÎÏĪ': 'I',
    'òóôõöøō': 'o',
    'ÒÓÔÕÖØŌ': 'O',
    'ùúûüū': 'u',
    'ÙÚÛÜŪ': 'U',
    'ñ': 'n',
    'Ñ': 'N',
    'ç': 'c',
    'Ç': 'C',
    'ß': 'ss',
    'ýÿ': 'y',
    'Ý': 'Y',
  };

  String _ascii(String input) {
    final output = StringBuffer();

    for (final rune in input.runes) {
      final character = String.fromCharCode(rune);

      if (rune >= 32 && rune < 127) {
        output.write(character);
      } else if (character == '\u2019' || character == '\u2018') {
        output.write("'");
      } else if (character == '\u201C' || character == '\u201D') {
        output.write('"');
      } else if (character == '\u2013' || character == '\u2014') {
        output.write('-');
      } else {
        for (final entry in _accents.entries) {
          if (entry.key.contains(character)) {
            output.write(entry.value);
            break;
          }
        }
      }
    }

    return output.toString().trim();
  }

  Future<void> _sendMeta(String title, String artist) {
    return _enqueueBle(() async {
      final characteristic = _char;
      final device = _dev;

      if (characteristic == null || device == null) {
        _setStatus('Metadata ready; waiting for ESP-Art connection');
        return;
      }

      try {
        // Packet type 0x04 uses one GATT write, so keep the entire metadata
        // payload within the negotiated ATT write size.
        final int maxDataLength = (device.mtuNow - 4).clamp(1, 509);
        final String metadata = '${_ascii(title)}\n${_ascii(artist)}';
        final List<int> bytes = ascii.encode(metadata);
        final List<int> clipped =
            bytes.length > maxDataLength ? bytes.sublist(0, maxDataLength) : bytes;

        await characteristic.write(
          [0x04, ...clipped],
          withoutResponse: false,
        );
      } catch (e) {
        _setStatus('Metadata send error: $e');
      }
    });
  }

  // ---------------------------------------------------------------------------
  // iTunes artwork lookup
  // ---------------------------------------------------------------------------

  Future<Uint8List?> _fetchArt(String title, String artist) async {
    try {
      final uri = Uri.https('itunes.apple.com', '/search', {
        'term': '$artist $title',
        'entity': 'song',
        'limit': '1',
      });

      final response =
          await http.get(uri).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) return null;

      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;

      final dynamic count = decoded['resultCount'];
      final dynamic results = decoded['results'];

      if (count is! num || count == 0 || results is! List || results.isEmpty) {
        return null;
      }

      final first = results.first;
      if (first is! Map<String, dynamic>) return null;

      final artworkUrl = first['artworkUrl100'];
      if (artworkUrl is! String || artworkUrl.isEmpty) return null;

      final largeUrl =
          artworkUrl.replaceFirst('100x100bb', '300x300bb');

      final artworkResponse = await http
          .get(Uri.parse(largeUrl))
          .timeout(const Duration(seconds: 8));

      if (artworkResponse.statusCode != 200 ||
          artworkResponse.bodyBytes.isEmpty) {
        return null;
      }

      return Uint8List.fromList(artworkResponse.bodyBytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleTrack(String title, String artist) async {
    title = title.trim();
    artist = artist.trim();

    if (title.isEmpty && artist.isEmpty) return;

    final key = '$artist - $title';
    if (key == _lastKey) return;

    _lastKey = key;
    final int generation = ++_trackGeneration;

    _lastTitle = title;
    _lastArtist = artist;
    _lastJpg = null;

    _setNowPlaying(key);

    // Send metadata first. Artwork follows when the lookup completes.
    await _sendMeta(title, artist);

    final jpg = await _fetchArt(title, artist);

    // Ignore a slow response belonging to an older song.
    if (_disposed || generation != _trackGeneration) return;

    if (jpg == null) {
      _setStatus('Artwork not found for this track');
      return;
    }

    if (mounted && !_disposed) {
      setState(() => _lastJpg = jpg);
    }

    await _sendJpeg(jpg);
  }

  // ---------------------------------------------------------------------------
  // iOS Now Playing (Apple Music)
  // ---------------------------------------------------------------------------

  Future<void> _startNowPlaying() async {
    try {
      final bool authorized =
          await _method.invokeMethod<bool>('requestAuth') ?? false;

      if (!authorized) {
        _setStatus('Media library permission denied');
        return;
      }

      // Keep the app alive in the background (silent audio session, iOS).
      try {
        await _method.invokeMethod('startKeepAlive');
      } catch (_) {}

      await _npSub?.cancel();
      _npSub = _events.receiveBroadcastStream().listen(
        (event) {
          if (event is! Map) return;

          final map = Map<String, dynamic>.from(event);
          final title = (map['title'] ?? '').toString();
          final artist = (map['artist'] ?? '').toString();

          _handleTrack(title, artist);
        },
        onError: (Object error) {
          _setStatus('Now Playing error: $error');
        },
      );
      // Fallback: the change notification can be missed in the background,
      // so also check the current song every 5 seconds (deduplicated by _lastKey).
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        try {
          final cur = await _method.invokeMethod<Map>('current');
          if (cur == null) return;
          _handleTrack(
            (cur['title'] ?? '').toString(),
            (cur['artist'] ?? '').toString(),
          );
        } catch (_) {}
      });
    } catch (e) {
      _setStatus('Now Playing setup error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Media Display TFT'),
        actions: [
          IconButton(
            tooltip: 'Reconnect',
            onPressed: _dev == null && !_connecting ? _scan : null,
            icon: const Icon(Icons.bluetooth_searching),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Icon(
                _dev == null ? Icons.bluetooth_disabled : Icons.bluetooth_connected,
                color: _dev == null ? Colors.grey : Colors.green,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text('BLE: $_status')),
            ],
          ),
          const SizedBox(height: 8),
          Text('Now playing: $_nowPlaying'),
          const SizedBox(height: 16),
          if (_lastJpg != null)
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  _lastJpg!,
                  width: 240,
                  height: 240,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const Text('Cannot display artwork'),
                ),
              ),
            ),
          const Divider(height: 32),
          const Text(
            'Manual testing',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          TextField(
            controller: _titleCtl,
            decoration: const InputDecoration(labelText: 'Title'),
            textInputAction: TextInputAction.next,
          ),
          TextField(
            controller: _artistCtl,
            decoration: const InputDecoration(labelText: 'Artist'),
            onSubmitted: (_) => _manualSend(),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _manualSend,
            child: const Text('Fetch & send'),
          ),
        ],
      ),
    );
  }

  void _manualSend() {
    _lastKey = '';
    _handleTrack(_titleCtl.text, _artistCtl.text);
  }
}
