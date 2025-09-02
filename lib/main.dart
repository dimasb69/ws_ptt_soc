import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

import 'audio_handler.dart';
import 'utils.dart';

const String _sampleAudioAssetPath = "assets/prueba.ogg";
const String _sampleAudioFilenameForServer = "simulated_audio.ogg";
const String _contentTypeForOgg = "audio/ogg";
const String _tempAudioFilenameReceiverBase = "ptt_rcv_playback";

void main() {
  runApp(PTTApp());
}

class PTTApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PTT - Paso 2 Rev (Streamlined)',
      theme: ThemeData(primarySwatch: Colors.teal, useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(primarySwatch: Colors.teal, useMaterial3: true, brightness: Brightness.dark),
      home: PTTHomePage(),
    );
  }
}

enum EmisorLocalPttStatus { idle, requesting, transmitting }

class ReceivedAudioMessage {
  final String id;
  final String senderUsername;
  final String filename;
  final String url;
  bool isDownloading;
  bool isPlaying;
  bool hasError;
  String? localPath;

  ReceivedAudioMessage({
    required this.id,
    required this.senderUsername,
    required this.filename,
    required this.url,
    this.isDownloading = false,
    this.isPlaying = false,
    this.hasError = false,
    this.localPath,
  });
}

class PTTHomePage extends StatefulWidget {
  @override
  _PTTHomePageState createState() => _PTTHomePageState();
}

class _PTTHomePageState extends State<PTTHomePage> {
  final _uuid = Uuid();
  late String clientId;

  String username = "";
  List<String> servers = ["ws://192.168.100.26:8000/ws"]; // << RECUERDA CAMBIAR ESTA IP
  String? selectedServer;

  WebSocketChannel? channel;
  StreamSubscription? _websocketSubscription;
  bool connected = false;

  EmisorLocalPttStatus _emisorPttStatus = EmisorLocalPttStatus.idle;
  String? _currentGlobalTransmitterId;
  String? _currentGlobalTransmitterName;

  bool _isMicPermissionGranted = false;
  late AudioHandlerService _audioHandlerService;
  bool _isAudioHandlerServiceReady = false;

  ReceivedAudioMessage? _lastReceivedMessageForAutoPlay;

  String? _receiverTempDirectoryPath;

  bool _isAudioMessageCurrentlyPlaying = false;
  String? _idOfMessageCurrentlyPlaying;

  String get _logPrefix => "[${clientId.substring(0,5)} (${username.isNotEmpty ? username.substring(0,min(username.length,3)) : 'USR'})]";

  @override
  void initState() {
    super.initState();
    clientId = _uuid.v4();
    if (servers.isNotEmpty) selectedServer = servers.first;

    _audioHandlerService = AudioHandlerService();
    _audioHandlerService.setClientIdForLogs(clientId);
    _initPermissionsAndAudio();
    _initReceiverDirectory();
  }

  Future<void> _initPermissionsAndAudio() async {
    if (kDebugMode) print("$_logPrefix PASO_2_STREAMLINED: Inicializando permisos y audio...");
    var micStatus = await Permission.microphone.request();
    _isMicPermissionGranted = micStatus == PermissionStatus.granted;

    await _audioHandlerService.initAudio();

    if (mounted) {
      setState(() { _isAudioHandlerServiceReady = true; });
    }

    if (kDebugMode) {
      if (_isMicPermissionGranted) { print("$_logPrefix PASO_2_STREAMLINED: Permiso de micrófono CONCEDIDO."); }
      else { print("$_logPrefix PASO_2_STREAMLINED: Permiso de micrófono DENEGADO."); _showMessage("Permiso de Micrófono Denegado.", isError: true); }
      print("$_logPrefix PASO_2_STREAMLINED: AudioHandlerService listo.");
    }
  }

  Future<void> _initReceiverDirectory() async {
    try {
      final directory = await getTemporaryDirectory();
      _receiverTempDirectoryPath = directory.path;
      if (kDebugMode) print("$_logPrefix PASO_2_STREAMLINED: Directorio temporal: $_receiverTempDirectoryPath");
    } catch (e) {
      if (kDebugMode) print("$_logPrefix PASO_2_STREAMLINED_ERR: Preparando directorio: $e");
    }
  }

  Future<void> _playLocalBeepInicio() async {
    if (_isAudioMessageCurrentlyPlaying) return;
    if (!_isAudioHandlerServiceReady || !mounted) return;
    if (kDebugMode) print("$_logPrefix BEEP: INICIO local.");
    await _audioHandlerService.playBeep('assets/beep2.wav', 'LocalBeepInicio');
  }

  Future<void> _playLocalBeepFin() async {
    if (_isAudioMessageCurrentlyPlaying) return;
    if (!_isAudioHandlerServiceReady || !mounted) return;
    if (kDebugMode) print("$_logPrefix BEEP: FIN local.");
    await _audioHandlerService.playBeep('assets/bepbep2.wav', 'LocalBeepFin');
  }

  Future<void> _sendSimulatedOggFileFromAssetsAndNotifyStop() async {
    if (!connected) {
      if (mounted && _emisorPttStatus == EmisorLocalPttStatus.transmitting) {
        setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
      }
      return;
    }

    if (kDebugMode) print("$_logPrefix SIM_OGG_SEND: Leyendo asset '$_sampleAudioAssetPath'...");
    try {
      final ByteData byteData = await rootBundle.load(_sampleAudioAssetPath);
      final Uint8List fileBytes = byteData.buffer.asUint8List();
      final String base64AudioData = base64Encode(fileBytes);

      final message = {
        "type": "new_audio_message", "filename": _sampleAudioFilenameForServer,
        "content_type": _contentTypeForOgg, "data": base64AudioData
      };
      channel?.sink.add(jsonEncode(message));
      if (kDebugMode) print("$_logPrefix SIM_OGG_SEND: 'new_audio_message' enviado.");

    } catch (e) {
      if (kDebugMode) print("$_logPrefix SIM_OGG_SEND_ERR: $e");
      _showMessage("Error al enviar audio: $e", isError: true);
    } finally {
      if (connected) {
        channel?.sink.add(jsonEncode({"type": "stop_transmit"}));
        if (kDebugMode) print("$_logPrefix SIM_OGG_SEND: 'stop_transmit' enviado.");
      }
    }
  }

  void _connect() {
    if (username.trim().isEmpty) { _showMessage("Ingresa un nombre.", isError: true); return; }
    if (selectedServer == null || selectedServer!.isEmpty) { _showMessage("Selecciona un servidor.", isError: true); return; }
    if (!_isMicPermissionGranted && kReleaseMode) { _showMessage("Permiso de micrófono necesario.", isError: true); return; }
    if (!_isAudioHandlerServiceReady) { _showMessage("Sistema de audio no listo.", isError: true); return; }
    if (connected) return;

    final url = "$selectedServer/$clientId/$username";
    if (kDebugMode) print("$_logPrefix CONN: Conectando a $url...");
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
      if(mounted) {
        setState(() {
          connected = true; _emisorPttStatus = EmisorLocalPttStatus.idle;
          _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null;
          _lastReceivedMessageForAutoPlay = null;
          _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null;
        });
      }
      _showMessage("Conectado como '$username'", durationSeconds: 2);
      _websocketSubscription = channel!.stream.listen(
            (message) { if (!mounted) return; _handleServerMessage(message); },
        onDone: () {
          if (!mounted || channel == null) return;
          if (kDebugMode) print("$_logPrefix CONN_EVENT: WebSocket Desconectado (onDone).");
          _showMessage("Desconexión del servidor.", isError: true);
          _audioHandlerService.stopCurrentMessagePlayback();
          if(mounted) {
            setState(() {
              connected = false; _emisorPttStatus = EmisorLocalPttStatus.idle;
              _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null;
              _lastReceivedMessageForAutoPlay = null;
              _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null;
            });
          }
        },
        onError: (error) {
          if (!mounted || channel == null) return;
          if (kDebugMode) print("$_logPrefix CONN_ERR: WebSocket Error: $error");
          _showMessage("Error de conexión: $error", isError: true);
          _audioHandlerService.stopCurrentMessagePlayback();
          if(mounted) {
            setState(() {
              connected = false; _emisorPttStatus = EmisorLocalPttStatus.idle;
              _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null;
              _lastReceivedMessageForAutoPlay = null;
              _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null;
            });
          }
        },
      );
    } catch (e) {
      if (kDebugMode) print("$_logPrefix CONN_EXC: $e");
      _showMessage("Excepción: $e", isError: true);
      if(mounted) setState(() { connected = false; });
    }
  }

  void _disconnect() {
    if (!connected && channel == null) return;
    if (kDebugMode) print("$_logPrefix CONN_ACTION: Desconexión local...");
    _audioHandlerService.stopCurrentMessagePlayback();
    if (mounted) {
      setState(() {
        connected = false; _emisorPttStatus = EmisorLocalPttStatus.idle;
        _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null;
        _lastReceivedMessageForAutoPlay = null;
        _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null;
      });
    }
    _showMessage("Desconectando...", durationSeconds: 1);
    _websocketSubscription?.cancel(); _websocketSubscription = null;
    channel?.sink.close().catchError((e) { if (kDebugMode) print("$_logPrefix CONN_ERR: Cerrando sink: $e"); }); channel = null;
    if (kDebugMode) print("$_logPrefix CONN_ACTION: Desconexión completa.");
  }

  void _showMessage(String msg, {bool isError = false, int? durationSeconds}) {
    if (mounted) {
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: Duration(seconds: durationSeconds ?? (isError ? 4 : 2)),
            backgroundColor: isError ? Colors.red.shade700 : Colors.teal.shade700,
            behavior: SnackBarBehavior.floating,
          )
      );
    }
    if (kDebugMode) { print("$_logPrefix UI_MSG: ($msg) ${isError ? "[ERROR]" : ""}"); }
  }

  void _addServer() {
    showDialog(context: context, builder: (context) {
      final controller = TextEditingController();
      return AlertDialog(
        title: Text("Agregar URL Servidor"),
        content: TextField(controller: controller, decoration: InputDecoration(hintText: "ws://ip:puerto/ws"), keyboardType: TextInputType.url),
        actions: [
          TextButton(onPressed: () {
            final url = controller.text.trim();
            if (url.isNotEmpty && (url.startsWith("ws://") || url.startsWith("wss://"))) {
              if (!servers.contains(url)) {
                if (mounted) setState(() { servers.add(url); selectedServer = url; });
                _showMessage("Servidor '$url' añadido.");
              } else { _showMessage("Servidor ya existe.", isError: true); }
            } else { _showMessage("URL inválida.", isError: true); }
            Navigator.pop(context);
          }, child: Text("Agregar")),
          TextButton(onPressed: () => Navigator.pop(context), child: Text("Cancelar")),
        ],
      );
    });
  }

  void _removeServer(String url) {
    if (servers.length <= 1 && servers.contains(url)) {
      _showMessage("No puedes eliminar el único servidor.", isError: true); return;
    }
    if (mounted) {
      setState(() {
        servers.remove(url);
        if (selectedServer == url) selectedServer = servers.isNotEmpty ? servers.first : null;
      });
    }
    _showMessage("Servidor '$url' eliminado.");
  }

  void _handleServerMessage(dynamic rawMessage) async {
    if (!mounted) return;
    try {
      final data = jsonDecode(rawMessage as String);
      final type = data['type'] as String?;
      if (kDebugMode && !(type == 'new_audio_message' || type == 'incoming_audio_message')) {
        print("$_logPrefix MSG_RECV: Tipo='$type', Data='$data'");
      } else if (kDebugMode) {
        print("$_logPrefix MSG_RECV: Tipo='$type', Sender: ${data['username'] ?? data['sender_username']}, Filename: ${data['filename']}");
      }


      switch (type) {
        case 'transmit_approved':
          if (_emisorPttStatus == EmisorLocalPttStatus.requesting) {
            if (mounted) {
              setState(() { _emisorPttStatus = EmisorLocalPttStatus.transmitting; });
              await _playLocalBeepInicio();
            }
          }
          break;

        case 'transmit_denied':
          _showMessage("No puedes enviar: ${data['reason']}", isError: true, durationSeconds: 3);
          if(mounted && _emisorPttStatus == EmisorLocalPttStatus.requesting) {
            setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
          }
          break;

        case 'transmit_started':
          final transmitterId = data['client_id'] as String?;
          final transmitterUsername = data['username'] as String?;

          bool amITheNewTransmitter = transmitterId == clientId;
          String? previousGlobalTransmitterId = _currentGlobalTransmitterId;

          if (mounted) {
            setState(() {
              _currentGlobalTransmitterId = transmitterId;
              _currentGlobalTransmitterName = transmitterUsername ?? 'Desconocido';
            });

            if (amITheNewTransmitter) {
              _showMessage("Canal abierto. Suelta PTT para enviar.", durationSeconds: 2);
              if (_emisorPttStatus != EmisorLocalPttStatus.transmitting) {
                setState(() => _emisorPttStatus = EmisorLocalPttStatus.transmitting);
              }
            } else {
              _showMessage("${transmitterUsername ?? 'Alguien'} está 'hablando'...", durationSeconds: 2);
              if (previousGlobalTransmitterId == null && !_isAudioMessageCurrentlyPlaying) {
                await _playLocalBeepInicio();
              }
            }
          }
          break;

        case 'transmit_stopped':
          final stopperId = data['client_id'] as String?;
          final stopperUsername = data['username'] as String?;

          bool wasITheOneStopping = stopperId == clientId;
          bool wasSomeoneElseStopping = _currentGlobalTransmitterId != null && _currentGlobalTransmitterId == stopperId && !wasITheOneStopping;

          if (mounted) {
            if (_currentGlobalTransmitterId == stopperId) {
              setState(() {
                _currentGlobalTransmitterId = null;
                _currentGlobalTransmitterName = null;
              });
            }
            if (wasITheOneStopping && _emisorPttStatus == EmisorLocalPttStatus.transmitting) {
              setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
            }
          }
          if (wasSomeoneElseStopping) {
            _showMessage("Transmisión de ${stopperUsername ?? 'alguien'} finalizada.", durationSeconds: 1);
            if (!_isAudioMessageCurrentlyPlaying) await _playLocalBeepFin();
          } else if (wasITheOneStopping) {
            _showMessage("Tu envío de archivo ha finalizado.", durationSeconds: 1);
          }
          break;

        case 'incoming_audio_message':
          final messageId = data['message_id'] as String?;
          final senderClientId = data['sender_client_id'] as String?;
          final senderUsername = data['sender_username'] as String?;
          final filenameFromServer = data['filename'] as String?;

          final audioUrl = buildAudioDownloadUrl(
            selectedServerUrl: selectedServer, messageId: messageId, filenameFromServer: filenameFromServer,
          );

          if (messageId != null && senderClientId != null && senderUsername != null && filenameFromServer != null && audioUrl != null) {
            if (senderClientId != clientId) {
              final newMsg = ReceivedAudioMessage(
                  id: messageId, senderUsername: senderUsername,
                  filename: filenameFromServer, url: audioUrl
              );
              if (mounted) {
                setState(() { _lastReceivedMessageForAutoPlay = newMsg; });
                _showMessage("Nuevo mensaje de $senderUsername.", durationSeconds: 2);
                if (_lastReceivedMessageForAutoPlay != null) {
                  _downloadAndPlayReceivedAudio(_lastReceivedMessageForAutoPlay!);
                }
              }
            }
          }
          break;

        default: break;
      }
    } catch (e, s) { if (kDebugMode) print("$_logPrefix MSG_RECV_ERR: $e. Stack: $s. Mensaje: $rawMessage"); }
  }

  Future<void> _onPttPress() async {
    if (!connected || !_isAudioHandlerServiceReady || _isAudioMessageCurrentlyPlaying) return;
    if (!_isMicPermissionGranted && kReleaseMode) { _showMessage("Permiso de micrófono necesario.", isError: true); return; }

    if (_emisorPttStatus == EmisorLocalPttStatus.idle && _currentGlobalTransmitterId == null) {
      if(mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.requesting; });
      channel?.sink.add(jsonEncode({"type": "request_transmit"}));
      _showMessage("Solicitando...", durationSeconds: 1);
    } else if (_currentGlobalTransmitterId != null && _currentGlobalTransmitterId != clientId) {
      _showMessage("${_currentGlobalTransmitterName ?? 'Alguien'} transmite.", isError: true);
    }
  }

  Future<void> _onPttRelease() async {
    if (!connected || !_isAudioHandlerServiceReady) return;

    if (_emisorPttStatus == EmisorLocalPttStatus.transmitting) {
      if (!_isAudioMessageCurrentlyPlaying) await _playLocalBeepFin();
      if (!mounted) return;
      await _sendSimulatedOggFileFromAssetsAndNotifyStop();
      if (mounted) {
        setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
      }
    } else if (_emisorPttStatus == EmisorLocalPttStatus.requesting) {
      await _audioHandlerService.cancelCurrentBeep();
      if (mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
      _showMessage("Solicitud cancelada.", durationSeconds: 1);
    }
  }

  Future<void> _downloadAndPlayReceivedAudio(ReceivedAudioMessage messageToPlay) async {
    if (_receiverTempDirectoryPath == null) { _showMessage("Directorio no listo.", isError: true); return; }

    if (_isAudioMessageCurrentlyPlaying && _idOfMessageCurrentlyPlaying != messageToPlay.id) {
      _showMessage("Otro mensaje reproduciéndose.", isError: true);
      return;
    }
    if (_isAudioMessageCurrentlyPlaying && _idOfMessageCurrentlyPlaying == messageToPlay.id) {
      await _audioHandlerService.stopCurrentMessagePlayback();
      return;
    }

    if(mounted) setState(() { messageToPlay.isDownloading = true; messageToPlay.hasError = false; });

    String localFileName = generateLocalFilenameForDownload(
        messageId: messageToPlay.id, originalFilename: messageToPlay.filename,
        tempFilenameBase: _tempAudioFilenameReceiverBase
    );
    String localFilePath = '${_receiverTempDirectoryPath!}/$localFileName';

    try {
      final response = await http.get(Uri.parse(messageToPlay.url));
      if (response.statusCode == 200) {
        final File file = File(localFilePath);
        await file.writeAsBytes(response.bodyBytes);
        if(mounted) setState(() { messageToPlay.localPath = localFilePath; });
        if (!mounted) return;

        setState(() {
          _isAudioMessageCurrentlyPlaying = true;
          _idOfMessageCurrentlyPlaying = messageToPlay.id;
          messageToPlay.isPlaying = true;
        });

        await _audioHandlerService.playAudioFile(
            localFilePath, messageToPlay.id,
            onStarted: () { if(mounted && _idOfMessageCurrentlyPlaying == messageToPlay.id) setState(() => messageToPlay.isPlaying = true); },
            onCompleted: () {
              if (mounted) {
                setState(() {
                  messageToPlay.isPlaying = false;
                  if(_idOfMessageCurrentlyPlaying == messageToPlay.id){
                    _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null;
                  }
                });
              }
            },
            onError: (e) {
              _showMessage("Error al reproducir: $e", isError: true);
              if (mounted) {
                setState(() {
                  messageToPlay.isPlaying = false; messageToPlay.hasError = true;
                  if(_idOfMessageCurrentlyPlaying == messageToPlay.id){
                    _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null;
                  }
                });
              }
            }
        );
      } else { throw Exception('Fallo al descargar: ${response.statusCode}'); }
    } catch (e) {
      _showMessage("Error al descargar: $e", isError: true);
      if (mounted) {
        setState(() {
          messageToPlay.hasError = true;
          if(_idOfMessageCurrentlyPlaying == messageToPlay.id){
            _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null;
          }
        });
      }
    } finally {
      if (mounted) setState(() => messageToPlay.isDownloading = false);
    }
  }

  @override
  void dispose() {
    _audioHandlerService.stopCurrentMessagePlayback();
    _websocketSubscription?.cancel();
    if(channel != null) { channel!.sink.close().catchError((e){}); }
    _audioHandlerService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String pttButtonText = ""; Color pttButtonColor = Colors.grey; IconData pttIcon = Icons.mic;
    bool pttButtonEnabled = false; String channelStatusText = "CANAL LIBRE"; Color channelStatusColor = Colors.green;

    bool audioSystemReady = _isAudioHandlerServiceReady;
    bool canConnect = username.trim().isNotEmpty && selectedServer != null &&
        (_isMicPermissionGranted || kDebugMode) && audioSystemReady;

    if (connected) {
      if (_currentGlobalTransmitterId != null) {
        if (_currentGlobalTransmitterId == clientId) {
          channelStatusText = "TU TRANSMITES (SIMULADO)"; channelStatusColor = Colors.redAccent.shade700;
        } else {
          channelStatusText = "EN CANAL: ${_currentGlobalTransmitterName ?? 'Desconocido'}";
          channelStatusColor = Colors.orange.shade700;
        }
      } else if (_isAudioMessageCurrentlyPlaying && _idOfMessageCurrentlyPlaying != null) {
        channelStatusText = "REPRODUCIENDO AUDIO..."; // Simplificado, no necesitamos buscar el sender para el status text
        channelStatusColor = Colors.purple.shade400;
      }
    }

    if (!connected) { /* No PTT button logic */ }
    else if (!_isMicPermissionGranted && kReleaseMode) {
      pttButtonText = "PERMISO MIC"; pttIcon = Icons.mic_off_rounded; pttButtonColor = Colors.red.shade300;
    } else if (!audioSystemReady) {
      pttButtonText = "AUDIO NO LISTO"; pttIcon = Icons.volume_off_rounded; pttButtonColor = Colors.blueGrey.shade300;
    } else {
      if (_isAudioMessageCurrentlyPlaying) {
        pttButtonText = "REPRODUCIENDO..."; pttIcon = Icons.speaker_phone_rounded;
        pttButtonColor = Colors.purple.shade300; pttButtonEnabled = false;
      }
      else if (_currentGlobalTransmitterId != null && _currentGlobalTransmitterId != clientId) {
        pttButtonText = "${_currentGlobalTransmitterName ?? 'Alguien'} HABLA"; pttIcon = Icons.hearing_rounded;
        pttButtonColor = Colors.orangeAccent.shade700; pttButtonEnabled = false;
      }
      else if (_emisorPttStatus == EmisorLocalPttStatus.requesting) {
        pttButtonText = "SOLICITANDO..."; pttIcon = Icons.timer_outlined; pttButtonColor = Colors.blueGrey; pttButtonEnabled = true;
      } else if (_emisorPttStatus == EmisorLocalPttStatus.transmitting) {
        pttButtonText = "SUELTA PARA ENVIAR"; pttIcon = Icons.mic_external_on_rounded; pttButtonColor = Colors.redAccent.shade700; pttButtonEnabled = true;
      } else {
        pttButtonText = "PULSA Y HABLA (SIM)"; pttIcon = Icons.mic_rounded; pttButtonColor = Colors.green.shade700; pttButtonEnabled = true;
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text("PTT - Streamlined ${username.isNotEmpty ? '($username)' : ''}")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!connected) ...[
              TextField(decoration: InputDecoration(labelText: "Tu Nombre", border: OutlineInputBorder(), prefixIcon: Icon(Icons.person_outline)), onChanged: (val) { if(mounted) setState(() => username = val.trim()); }, enabled: !connected ),
              SizedBox(height: 8), Text("Servidor:", style: Theme.of(context).textTheme.bodySmall),
              Row(children: [ Expanded(child: DropdownButtonHideUnderline(child: Container( padding: EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0), decoration: BoxDecoration(borderRadius: BorderRadius.circular(8.0), border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.7), width: 1)), child: DropdownButton<String>( value: selectedServer, items: servers.isEmpty ? [DropdownMenuItem(value: null, enabled: false, child: Text("Añade un servidor"))] : servers.map((s) => DropdownMenuItem(value: s, child: Row( children: [ Flexible(child: Text(s, overflow: TextOverflow.ellipsis)), if (!(servers.length == 1 && selectedServer == s)) IconButton(icon: Icon(Icons.delete_outline_rounded, size: 20), onPressed: () => _removeServer(s), padding: EdgeInsets.zero, constraints: BoxConstraints()) ], ))).toList(), onChanged: (val) { if (mounted) setState(() { selectedServer = val; }); }, isExpanded: true, hint: Text("Selecciona servidor"), underline: SizedBox.shrink(), borderRadius: BorderRadius.circular(8.0) ) ))), IconButton(icon: Icon(Icons.add_circle_outline_rounded), tooltip: "Añadir servidor", onPressed: _addServer) ]),
              SizedBox(height: 12), ElevatedButton.icon( icon: Icon(Icons.login_rounded), onPressed: canConnect ? _connect : null, label: Text("CONECTAR"), style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, padding: EdgeInsets.symmetric(vertical: 14)) ),
            ] else ...[
              Text("Conectado: $username", textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold)),
              Padding( padding: const EdgeInsets.symmetric(vertical: 4.0), child: Text( channelStatusText, textAlign: TextAlign.center, style: TextStyle(color: channelStatusColor, fontStyle: FontStyle.italic, fontWeight: FontWeight.bold ) ) ),
              SizedBox(height: 8), ElevatedButton.icon( icon: Icon(Icons.logout_rounded), onPressed: _disconnect, label: Text("DESCONECTAR"), style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey, padding: EdgeInsets.symmetric(vertical: 10)) ),
            ],
            Divider(height: 20, thickness: 1),
            if (connected)
              Expanded(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10.0),
                      child: GestureDetector(
                        onTapDown: pttButtonEnabled ? (_) => _onPttPress() : null,
                        onTapUp: pttButtonEnabled ? (_) => _onPttRelease() : null,
                        onLongPressStart: pttButtonEnabled ? (_) => _onPttPress() : null,
                        onLongPressEnd: pttButtonEnabled ? (_) => _onPttRelease() : null,
                        onLongPressCancel: pttButtonEnabled ? () => _onPttRelease() : null,
                        child: AnimatedContainer(
                            duration: Duration(milliseconds: 150),
                            padding: EdgeInsets.all(15),
                            constraints: BoxConstraints(minWidth: 120, minHeight: 120, maxWidth: 150, maxHeight: 150),
                            decoration: BoxDecoration(
                              color: pttButtonEnabled ? pttButtonColor : Colors.grey.shade300, shape: BoxShape.circle,
                              boxShadow: [ if(pttButtonEnabled) BoxShadow(color: pttButtonColor.withOpacity(0.5), blurRadius: 8, spreadRadius: 2) ],
                            ),
                            child: Column( mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center,
                              children: [ Icon(pttIcon, size: 30, color: Colors.white), SizedBox(height: 4), Container( width: 80, child: Text( pttButtonText, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 9), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis ) ) ],
                            )
                        ),
                      ),
                    ),
                    // No hay historial de mensajes visible en esta versión simplificada.
                    // El último mensaje se reproduce automáticamente.
                    // Puedes añadir un indicador de "Reproduciendo mensaje de X..." si lo deseas,
                    // usando _lastReceivedMessageForAutoPlay y _isAudioMessageCurrentlyPlaying.
                    if (_isAudioMessageCurrentlyPlaying && _lastReceivedMessageForAutoPlay != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 15.0),
                        child: Card(
                          elevation: 2,
                          child: ListTile(
                            leading: Icon(Icons.speaker_phone_rounded, color: Colors.purple.shade400),
                            title: Text("Reproduciendo audio de:"),
                            subtitle: Text(_lastReceivedMessageForAutoPlay!.senderUsername),
                            trailing: _lastReceivedMessageForAutoPlay!.isDownloading
                                ? SizedBox(width:20, height:20, child: CircularProgressIndicator(strokeWidth:2))
                                : IconButton(
                                icon: Icon(Icons.stop_circle_outlined, color: Colors.red),
                                onPressed: () => _downloadAndPlayReceivedAudio(_lastReceivedMessageForAutoPlay!) // Tocar de nuevo para detener
                            ),
                          ),
                        ),
                      )
                    else if (_lastReceivedMessageForAutoPlay != null && _lastReceivedMessageForAutoPlay!.hasError)
                      Padding(
                        padding: const EdgeInsets.only(top: 15.0),
                        child: Text("Error al reproducir el último mensaje.", style: TextStyle(color: Colors.red)),
                      )
                  ],
                ),
              )
            else Expanded(child: Center(child: Text( !_isMicPermissionGranted ? "Se requiere permiso." : "Conéctate para usar PTT."))),
          ],
        ),
      ),
    );
  }
}
