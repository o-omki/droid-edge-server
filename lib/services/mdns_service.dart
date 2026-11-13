import "dart:async";
import "dart:io";
import "dart:typed_data";

import "package:bonsoir/bonsoir.dart";

/// Broadcasts the local HTTP server on the LAN via:
/// 1. DNS-SD (`_http._tcp`) using `bonsoir` (Android NSD / Bonjour).
/// 2. A lightweight pure-Dart mDNS A-record responder on `224.0.0.251:5353`
///    so `android-edge.local` resolves directly to the device's LAN IPv4.
class MdnsService {
  MdnsService({this.hostname = "android-edge.local"});

  final String hostname;

  BonsoirBroadcast? _broadcast;
  RawDatagramSocket? _mdnsSocket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  String? _advertisedIp;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  /// Starts DNS-SD advertisement and the `.local` A-record responder.
  Future<void> start({
    required String ipAddress,
    required int port,
  }) async {
    await stop();
    _advertisedIp = ipAddress;
    _isRunning = true;

    await _startBonsoir(port: port);
    await _startARecordResponder(ipAddress: ipAddress);
  }

  /// Stops all mDNS advertisements and closes the UDP multicast socket.
  Future<void> stop() async {
    _isRunning = false;
    _advertisedIp = null;

    await _socketSub?.cancel();
    _socketSub = null;
    _mdnsSocket?.close();
    _mdnsSocket = null;

    final broadcast = _broadcast;
    _broadcast = null;
    if (broadcast != null) {
      try {
        await broadcast.stop();
      } catch (_) {}
    }
  }

  Future<void> _startBonsoir({required int port}) async {
    try {
      final service = BonsoirService(
        name: "Droid Edge Server",
        type: "_http._tcp",
        port: port,
        attributes: {
          "hostname": hostname,
          "status": "/v1/status",
          "health": "/v1/health",
        },
      );
      final broadcast = BonsoirBroadcast(service: service);
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
    } catch (_) {
      // Tolerate platforms/tests where native NSD/Bonjour is unavailable.
    }
  }

  Future<void> _startARecordResponder({required String ipAddress}) async {
    final parsedIp = InternetAddress.tryParse(ipAddress);
    if (parsedIp == null ||
        parsedIp.type != InternetAddressType.IPv4 ||
        parsedIp.isLoopback) {
      return;
    }

    try {
      final multicastAddr = InternetAddress("224.0.0.251");
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        5353,
        reuseAddress: true,
        reusePort: true,
      );
      socket.multicastHops = 255;
      socket.joinMulticast(multicastAddr);
      _mdnsSocket = socket;

      // Send an unsolicited mDNS announcement on startup so caches warm up.
      _sendARecordResponse(
        socket: socket,
        target: multicastAddr,
        port: 5353,
        transactionId: 0,
        ipBytes: parsedIp.rawAddress,
      );

      _socketSub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        _handleIncomingMdnsPacket(
          socket: socket,
          datagram: datagram,
          ipBytes: parsedIp.rawAddress,
          multicastAddr: multicastAddr,
        );
      });
    } catch (_) {
      // Port 5353 or multicast may be restricted in headless/sandboxed tests.
    }
  }

  void _handleIncomingMdnsPacket({
    required RawDatagramSocket socket,
    required Datagram datagram,
    required Uint8List ipBytes,
    required InternetAddress multicastAddr,
  }) {
    final data = datagram.data;
    if (data.length < 12) return;

    final flags = (data[2] << 8) | data[3];
    final isQuery = (flags & 0x8000) == 0;
    if (!isQuery) return;

    final qdCount = (data[4] << 8) | data[5];
    if (qdCount == 0) return;

    var offset = 12;
    final targetName = hostname.toLowerCase();

    for (var i = 0; i < qdCount; i++) {
      final decoded = _readDnsName(data, offset);
      if (decoded == null) return;
      offset = decoded.nextOffset;
      if (offset + 4 > data.length) return;

      final qType = (data[offset] << 8) | data[offset + 1];
      final qClassRaw = (data[offset + 2] << 8) | data[offset + 3];
      final qClass = qClassRaw & 0x7FFF;
      final unicastRequested = (qClassRaw & 0x8000) != 0;
      offset += 4;

      final matchesName = decoded.name.toLowerCase() == targetName;
      final matchesType = qType == 1 || qType == 255; // A or ANY
      final matchesClass = qClass == 1 || qClass == 255; // IN or ANY

      if (matchesName && matchesType && matchesClass && _advertisedIp != null) {
        final txId = (data[0] << 8) | data[1];
        _sendARecordResponse(
          socket: socket,
          target: unicastRequested ? datagram.address : multicastAddr,
          port: unicastRequested ? datagram.port : 5353,
          transactionId: txId,
          ipBytes: ipBytes,
        );
        return;
      }
    }
  }

  void _sendARecordResponse({
    required RawDatagramSocket socket,
    required InternetAddress target,
    required int port,
    required int transactionId,
    required Uint8List ipBytes,
  }) {
    final encodedName = _encodeDnsName(hostname);
    final builder = BytesBuilder()
      ..addByte((transactionId >> 8) & 0xFF)
      ..addByte(transactionId & 0xFF)
      ..add(const [0x84, 0x00]) // Standard query response, authoritative
      ..add(const [0x00, 0x00]) // QDCOUNT = 0
      ..add(const [0x00, 0x01]) // ANCOUNT = 1
      ..add(const [0x00, 0x00]) // NSCOUNT = 0
      ..add(const [0x00, 0x00]) // ARCOUNT = 0
      ..add(encodedName)
      ..add(const [0x00, 0x01]) // TYPE = A
      ..add(const [0x80, 0x01]) // CLASS = IN + cache-flush bit
      ..add(const [0x00, 0x00, 0x00, 0x78]) // TTL = 120s
      ..add(const [0x00, 0x04]) // RDLENGTH = 4
      ..add(ipBytes);

    try {
      socket.send(builder.toBytes(), target, port);
    } catch (_) {}
  }

  static Uint8List _encodeDnsName(String name) {
    final builder = BytesBuilder();
    for (final label in name.split(".")) {
      if (label.isEmpty) continue;
      final bytes = label.codeUnits;
      builder.addByte(bytes.length);
      builder.add(bytes);
    }
    builder.addByte(0);
    return builder.toBytes();
  }

  static ({String name, int nextOffset})? _readDnsName(
    Uint8List data,
    int startOffset,
  ) {
    final labels = <String>[];
    var offset = startOffset;
    var jumped = false;
    var returnOffset = 0;
    var guard = 0;

    while (offset < data.length && guard++ < 64) {
      final length = data[offset];
      if (length == 0) {
        if (!jumped) returnOffset = offset + 1;
        return (name: labels.join("."), nextOffset: returnOffset);
      }

      if ((length & 0xC0) == 0xC0) {
        if (offset + 1 >= data.length) return null;
        if (!jumped) returnOffset = offset + 2;
        offset = ((length & 0x3F) << 8) | data[offset + 1];
        jumped = true;
        continue;
      }

      offset += 1;
      if (offset + length > data.length) return null;
      labels.add(String.fromCharCodes(data, offset, offset + length));
      offset += length;
    }

    return null;
  }
}

