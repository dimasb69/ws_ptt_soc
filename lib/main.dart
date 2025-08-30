import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';void main() {
  runApp(PTTApp());
}
class PTTApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PTT Multiusuario',
      home: PTTHomePage(),
    );
  }
}
class PTTHomePage extends StatefulWidget {
  @override
  _PTTHomePageState createState() => _PTTHomePageState();
}
class _PTTHomePageState extends State<PTTHomePage> {
  final _uuid = Uuid();
  late String clientId;
  String username = "";
  List<String> servers = ["ws://localhost:8000/ws"];
  String? selectedServer;
  WebSocketChannel? channel;
  bool connected = false;
  bool transmitting = false;
  String? currentTransmitterId;
  String? currentTransmitterName;
  FlutterSoundRecorder? _recorder;
  FlutterSoundPlayer? _player;
  StreamSubscription? _websocketSubscription;
  @override
  void initState() {
    super.initState();
    clientId = _uuid.v4();
    selectedServer = servers.first;
    _recorder = FlutterSoundRecorder();_player = FlutterSoundPlayer();
    _initAudio();
  }
  Future<void> _initAudio() async {
    await _recorder!.openRecorder();
    await _player!.openPlayer();
    await Permission.microphone.request();
  }
  @override
  void dispose() {
    _websocketSubscription?.cancel();
    _recorder?.closeRecorder();
    _player?.closePlayer();
    channel?.sink.close();
    super.dispose();
  }
  void _connect() {
    if (username.isEmpty) {
      _showMessage("Por favor ingresa un nombre de usuario");
      return;
    }
    final url = "$selectedServer/$clientId/$username";
    channel = WebSocketChannel.connect(Uri.parse(url));
    setState(() {
      connected = true;
    });
    _websocketSubscription = channel!.stream.listen((message) {
      _handleServerMessage(message);
    }, onDone: () {
      _showMessage("Conexión cerrada");
      setState(() {
        connected = false;
        transmitting = false;
        currentTransmitterId = null;
        currentTransmitterName = null;
      });
    }, onError: (error) {
      _showMessage("Error en conexión: $error");
      setState(() {
        connected = false;transmitting = false;
      });
    });
  }
  void _disconnect() {
    channel?.sink.close();
    setState(() {
      connected = false;
      transmitting = false;
      currentTransmitterId = null;
      currentTransmitterName = null;
    });
  }
  void _handleServerMessage(dynamic message) async {
    final data = jsonDecode(message);
    final type = data['type'];
    switch (type) {
      case 'transmit_started':
        setState(() {
          currentTransmitterId = data['client_id'];
          currentTransmitterName = data['username'];
        });
        if (currentTransmitterId != clientId) {
          _showMessage("${currentTransmitterName} está transmitiendo");
        }
        break;
      case 'transmit_stopped':
        setState(() {
          currentTransmitterId = null;
          currentTransmitterName = null;
        });
        _showMessage("Transmisión detenida");
        break;
      case 'transmit_approved':
        setState(() {
          transmitting = true;
        });
        _startRecording();
        break;
      case 'transmit_denied':
        _showMessage("No puedes transmitir: ${data['reason']}");
        break;case 'audio_chunk':
      if (data['client_id'] != clientId) {
        final base64Audio = data['data'];
        final bytes = base64Decode(base64Audio);
        await _playAudioChunk(bytes);
      }
      break;
      case 'pong':
// Opcional: manejar ping-pong
        break;
      default:
        print("Mensaje desconocido: $data");
    }
  }
  void _requestTransmit() {
    if (!connected) {
      _showMessage("No estás conectado");
      return;
    }
    if (transmitting) {
      _stopTransmit();
      return;
    }
    if (currentTransmitterId != null) {
      _showMessage("Otro usuario está transmitiendo");
      return;
    }
    channel!.sink.add(jsonEncode({"type": "request_transmit"}));
  }
  void _stopTransmit() {
    if (!transmitting) return;
    channel!.sink.add(jsonEncode({"type": "stop_transmit"}));
    _stopRecording();
    setState(() {
      transmitting = false;
    });
  }

  final List<int> audioBuffer = [];
  bool isSending = false;

  void _startRecording() async {
    try {
      // Primero detenemos cualquier grabación existente
      if (_recorder!.isRecording) {
        await _recorder!.stopRecorder();
      }

      // Creamos un controlador de flujo
      final streamController = StreamController<Uint8List>.broadcast();

      // Configuramos el manejador del stream
      streamController.stream.listen((buffer) async {
        final base64Data = base64Encode(buffer);
        if (channel != null && channel!.sink != null) {
          channel!.sink.add(jsonEncode({
            "type": "audio_chunk",
            "data": base64Data,
          }));
        }
      });

      // Iniciamos la grabación
      await _recorder!.startRecorder(
        toStream: streamController.sink,
        codec: Codec.pcm16,
        sampleRate: 16000,
        numChannels: 1,
      );
    } catch (e) {
      _showMessage("Error al iniciar grabación: $e");
    }
  }
 /* void _startRecording() async {
    await _recorder!.startRecorder(
      toStream: (buffer) {
        final base64Data = base64Encode(buffer);channel!.sink.add(jsonEncode({
          "type": "audio_chunk",
          "data": base64Data,
        }));
      },
      codec: Codec.pcm16,
      sampleRate: 16000,
      numChannels: 1,
    );
  }*/
  void _stopRecording() async {
    await _recorder!.stopRecorder();
  }
  Future<void> _playAudioChunk(Uint8List data) async {
// Nota: FlutterSoundPlayer no reproduce PCM directamente desde memoria.
// Para producción, se recomienda usar streaming de audio o guardar en archivo temporal.
// Aquí se omite la reproducción para simplificar.
  }
  void _showMessage(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
  void _addServer() {
    showDialog(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text("Agregar servidor"),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(hintText: "ws://ip:puerto/ws"),
          ),
          actions: [
            TextButton(
              onPressed: () {
                final url = controller.text.trim();
                if (url.isNotEmpty && !servers.contains(url)) {
                  setState(() {
                    servers.add(url);
                    selectedServer = url;});
                }
                Navigator.pop(context);
              },
              child: Text("Agregar"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("Cancelar"),
            ),
          ],
        );
      },
    );
  }
  void _removeServer(String url) {
    setState(() {
      servers.remove(url);
      if (selectedServer == url) {
        selectedServer = servers.isNotEmpty ? servers.first : null;
      }
    });
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("PTT Multiusuario"),
      ),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            if (!connected)
              TextField(
                decoration: InputDecoration(labelText: "Nombre de usuario"),
                onChanged: (val) => username = val.trim(),
              ),
            SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: DropdownButton<String>(
                  value: selectedServer,
                  items: servers
                      .map((s) => DropdownMenuItem(
                    value: s,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(child: Text(s)),
                        IconButton(
                          icon: Icon(Icons.delete, color: Colors.red),
                          onPressed: () => _removeServer(s),
                        )
                      ],
                    ),
                  ))
                      .toList(),
                  onChanged: (val) {
                    setState(() {
                      selectedServer = val;
                    });
                  },
                  isExpanded: true,
                ),
                ),
                IconButton(
                  icon: Icon(Icons.add),
                  onPressed: _addServer,
                )
              ],
            ),
            SizedBox(height: 10),
            connected
                ? ElevatedButton(
              onPressed: _disconnect,
              child: Text("Desconectar"),
            )
                : ElevatedButton(
              onPressed: _connect,
              child: Text("Conectar"),
            ),
            SizedBox(height: 20),
            Text(
              connected? "Conectado como $username\nID: $clientId"
                  : "No conectado",
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 20),
            Text(
              currentTransmitterId == null
                  ? "Nadie está transmitiendo"
                  : "Transmitiendo: $currentTransmitterName",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: connected ? _requestTransmit : null,
              style: ElevatedButton.styleFrom(
                foregroundColor: transmitting ? Colors.red : Colors.green,
                //primary: transmitting ? Colors.red : Colors.green,
                minimumSize: Size(double.infinity, 50),
              ),
              child: Text(transmitting ? "Dejar de transmitir" : "Presiona para transmitir"),
            ),
          ],
        ),
      ),
    );
  }
}