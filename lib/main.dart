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
import'package:permission_handler/permission_handler.dart';
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
      title: 'PTT - Paso 2 Rev (UI Fix)',
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
  // Para saber si el audio que se está reproduciendo ha terminado y poder resetear el icono del botón PTT
  bool _currentPlaybackFinishedOrError = true;

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
    if (kDebugMode) print("$_logPrefix UI_FIX: Inicializando permisos y audio...");
    var micStatus = await Permission.microphone.request();
    _isMicPermissionGranted = micStatus == PermissionStatus.granted;

    await _audioHandlerService.initAudio();

    if (mounted) {
      setState(() { _isAudioHandlerServiceReady = true; });
    }
    if (kDebugMode) {
      if (_isMicPermissionGranted) { print("$_logPrefix UI_FIX: Permiso de micrófono CONCEDIDO."); }
      else { print("$_logPrefix UI_FIX: Permiso de micrófono DENEGADO."); _showMessage("Permiso de Micrófono Denegado.", isError: true); }
      print("$_logPrefix UI_FIX: AudioHandlerService listo.");
    }
  }

  Future<void> _initReceiverDirectory() async {
    try {
      final directory = await getTemporaryDirectory();
      _receiverTempDirectoryPath = directory.path;
    } catch (e) { /* Log error */ }
  }

  Future<void> _playLocalBeepInicio() async {
    if (_isAudioMessageCurrentlyPlaying) return;
    if (!_isAudioHandlerServiceReady || !mounted) return;
    await _audioHandlerService.playBeep('assets/beep2.wav', 'LocalBeepInicio');
  }

  Future<void> _playLocalBeepFin() async {
    if (_isAudioMessageCurrentlyPlaying) return;
    if (!_isAudioHandlerServiceReady || !mounted) return;
    await _audioHandlerService.playBeep('assets/bepbep2.wav', 'LocalBeepFin');
  }

  Future<void> _sendSimulatedOggFileFromAssetsAndNotifyStop() async {
    if (!connected) {
      if (mounted && _emisorPttStatus == EmisorLocalPttStatus.transmitting) {
        setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
      }
      return;
    }
    try {
      final ByteData byteData = await rootBundle.load(_sampleAudioAssetPath);
      final Uint8List fileBytes = byteData.buffer.asUint8List();
      final String base64AudioData = base64Encode(fileBytes);
      final message = { "type": "new_audio_message", "filename": _sampleAudioFilenameForServer, "content_type": _contentTypeForOgg, "data": base64AudioData };
      channel?.sink.add(jsonEncode(message));
    } catch (e) { _showMessage("Error al enviar audio: $e", isError: true); }
    finally {
      if (connected) { channel?.sink.add(jsonEncode({"type": "stop_transmit"})); }
    }
  }

  void _connect() {
    if (username.trim().isEmpty || selectedServer == null || selectedServer!.isEmpty || (!_isMicPermissionGranted && kReleaseMode) || !_isAudioHandlerServiceReady || connected) return;
    final url = "$selectedServer/$clientId/$username";
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
      if(mounted) {
        setState(() {
          connected = true; _emisorPttStatus = EmisorLocalPttStatus.idle; _currentGlobalTransmitterId = null;
          _currentGlobalTransmitterName = null; _lastReceivedMessageForAutoPlay = null;
          _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null; _currentPlaybackFinishedOrError = true;
        });
      }
      _showMessage("Conectado como '$username'", durationSeconds: 2);
      _websocketSubscription = channel!.stream.listen(
            (message) { if (!mounted) return; _handleServerMessage(message); },
        onDone: () {
          if (!mounted || channel == null) return;
          _showMessage("Desconexión del servidor.", isError: true);
          _audioHandlerService.stopCurrentMessagePlayback();
          if(mounted) { setState(() { connected = false; _emisorPttStatus = EmisorLocalPttStatus.idle; _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null; _lastReceivedMessageForAutoPlay = null; _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null; _currentPlaybackFinishedOrError = true; }); }
        },
        onError: (error) {
          if (!mounted || channel == null) return;
          _showMessage("Error de conexión: $error", isError: true);
          _audioHandlerService.stopCurrentMessagePlayback();
          if(mounted) { setState(() { connected = false; _emisorPttStatus = EmisorLocalPttStatus.idle; _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null; _lastReceivedMessageForAutoPlay = null; _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null; _currentPlaybackFinishedOrError = true; }); }
        },
      );
    } catch (e) { _showMessage("Excepción: $e", isError: true); if(mounted) setState(() { connected = false; }); }
  }

  void _disconnect() {
    if (!connected && channel == null) return;
    _audioHandlerService.stopCurrentMessagePlayback();
    if (mounted) {
      setState(() {
        connected = false; _emisorPttStatus = EmisorLocalPttStatus.idle; _currentGlobalTransmitterId = null;
        _currentGlobalTransmitterName = null; _lastReceivedMessageForAutoPlay = null;
        _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null; _currentPlaybackFinishedOrError = true;
      });
    }
    _showMessage("Desconectando...", durationSeconds: 1);
    _websocketSubscription?.cancel(); _websocketSubscription = null;
    channel?.sink.close().catchError((e) {}); channel = null;
  }

  void _showMessage(String msg, {bool isError = false, int? durationSeconds}) {
    if (mounted) {
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar( SnackBar( content: Text(msg), duration: Duration(seconds: durationSeconds ?? (isError ? 4 : 2)), backgroundColor: isError ? Colors.red.shade700 : Colors.teal.shade700, behavior: SnackBarBehavior.floating ) );
    }
  }

  void _addServer() {
    showDialog(context: context, builder: (context) {
      final controller = TextEditingController();
      return AlertDialog( title: Text("Agregar Servidor"), content: TextField(controller: controller, decoration: InputDecoration(hintText: "ws://ip:puerto/ws"), keyboardType: TextInputType.url), actions: [ TextButton(onPressed: () { final url = controller.text.trim(); if (url.isNotEmpty && (url.startsWith("ws://") || url.startsWith("wss://"))) { if (!servers.contains(url)) { if (mounted) setState(() { servers.add(url); selectedServer = url; }); _showMessage("Servidor '$url' añadido."); } else { _showMessage("Servidor ya existe.", isError: true); } } else { _showMessage("URL inválida.", isError: true); } Navigator.pop(context); }, child: Text("Agregar")), TextButton(onPressed: () => Navigator.pop(context), child: Text("Cancelar")), ], ); }); }

  void _removeServer(String url) { if (servers.length <= 1 && servers.contains(url)) { _showMessage("No puedes eliminar.", isError: true); return; } if (mounted) { setState(() { servers.remove(url); if (selectedServer == url) selectedServer = servers.isNotEmpty ? servers.first : null; }); } _showMessage("Servidor '$url' eliminado."); }

  void _handleServerMessage(dynamic rawMessage) async {
    if (!mounted) return;
    try {
      final data = jsonDecode(rawMessage as String);
      final type = data['type'] as String?;

      switch (type) {
        case 'transmit_approved':
          if (_emisorPttStatus == EmisorLocalPttStatus.requesting) {
            if (mounted) { setState(() { _emisorPttStatus = EmisorLocalPttStatus.transmitting; }); await _playLocalBeepInicio(); }
          }
          break;
        case 'transmit_denied':
          _showMessage("No puedes enviar: ${data['reason']}", isError: true);
          if(mounted && _emisorPttStatus == EmisorLocalPttStatus.requesting) { setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; }); }
          break;
        case 'transmit_started':
          final tId = data['client_id'] as String?; final tName = data['username'] as String?;
          bool isMe = tId == clientId; String? prevId = _currentGlobalTransmitterId;
          if (mounted) {
            setState(() { _currentGlobalTransmitterId = tId; _currentGlobalTransmitterName = tName ?? 'Desconocido'; });
            if (isMe) {
              _showMessage("Canal abierto. Suelta PTT.", durationSeconds: 2);
              if (_emisorPttStatus != EmisorLocalPttStatus.transmitting) { setState(() => _emisorPttStatus = EmisorLocalPttStatus.transmitting); }
            } else {
              _showMessage("${tName ?? 'Alguien'} habla...", durationSeconds: 2);
              if (prevId == null && !_isAudioMessageCurrentlyPlaying) { await _playLocalBeepInicio(); }
            }
          }
          break;
        case 'transmit_stopped':
          final sId = data['client_id'] as String?; final sName = data['username'] as String?;
          bool wasMe = sId == clientId; bool wasOther = _currentGlobalTransmitterId != null && _currentGlobalTransmitterId == sId && !wasMe;
          if (mounted) {
            if (_currentGlobalTransmitterId == sId) { setState(() { _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null; }); }
            if (wasMe && _emisorPttStatus == EmisorLocalPttStatus.transmitting) { setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; }); }
          }
          if (wasOther) { _showMessage("Trans. de ${sName ?? 'alguien'} finalizada.", durationSeconds: 1); if (!_isAudioMessageCurrentlyPlaying) await _playLocalBeepFin(); }
          else if (wasMe) { _showMessage("Tu envío finalizado.", durationSeconds: 1); }
          break;
        case 'incoming_audio_message':
          final mId = data['message_id'] as String?; final scId = data['sender_client_id'] as String?;
          final suName = data['sender_username'] as String?; final fName = data['filename'] as String?;
          final audioUrl = buildAudioDownloadUrl(selectedServerUrl: selectedServer, messageId: mId, filenameFromServer: fName);
          if (mId != null && scId != null && suName != null && fName != null && audioUrl != null && scId != clientId) {
            final newMsg = ReceivedAudioMessage(id: mId, senderUsername: suName, filename: fName, url: audioUrl);
            if (mounted) {
              setState(() { _lastReceivedMessageForAutoPlay = newMsg; _currentPlaybackFinishedOrError = false; }); // Preparar para reproducir
              if (_lastReceivedMessageForAutoPlay != null) {
                _showMessage("Audio de $suName. Reproduciendo...", durationSeconds: 2);
                _downloadAndPlayReceivedAudio(_lastReceivedMessageForAutoPlay!);
              }
            }
          }
          break;
        default: break;
      }
    } catch (e) { /* Log error */ }
  }

  Future<void> _onPttPress() async {
    if (!connected || !_isAudioHandlerServiceReady || _isAudioMessageCurrentlyPlaying || (_currentGlobalTransmitterId != null && _currentGlobalTransmitterId != clientId) || _emisorPttStatus != EmisorLocalPttStatus.idle ) return;
    if (!_isMicPermissionGranted && kReleaseMode) { _showMessage("Permiso mic necesario.", isError: true); return; }
    if(mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.requesting; });
    channel?.sink.add(jsonEncode({"type": "request_transmit"}));
    _showMessage("Solicitando...", durationSeconds: 1);
  }

  Future<void> _onPttRelease() async {
    if (!connected || !_isAudioHandlerServiceReady) return;
    if (_emisorPttStatus == EmisorLocalPttStatus.transmitting) {
      if (!_isAudioMessageCurrentlyPlaying) await _playLocalBeepFin();
      if (!mounted) return;
      await _sendSimulatedOggFileFromAssetsAndNotifyStop();
      if (mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
    } else if (_emisorPttStatus == EmisorLocalPttStatus.requesting) {
      await _audioHandlerService.cancelCurrentBeep();
      if (mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
      _showMessage("Solicitud cancelada.", durationSeconds: 1);
    }
  }

  Future<void> _downloadAndPlayReceivedAudio(ReceivedAudioMessage msgToPlay) async {
    if (_receiverTempDirectoryPath == null) { _showMessage("Directorio no listo.", isError: true); setState(()=> _currentPlaybackFinishedOrError = true); return; }

    // Si se llama a reproducir mientras ya está sonando este mismo mensaje, AudioHandler lo detendrá.
    // Si es otro mensaje, AudioHandler también detendrá el anterior antes de reproducir el nuevo.
    // Aquí solo gestionamos el estado de la UI

    if(mounted) setState(() {
      msgToPlay.isDownloading = true; msgToPlay.hasError = false;
      _isAudioMessageCurrentlyPlaying = true; // Indicar que un proceso de reproducción ha comenzado
      _idOfMessageCurrentlyPlaying = msgToPlay.id;
      _currentPlaybackFinishedOrError = false; // Resetear
    });

    String localFileName = generateLocalFilenameForDownload(messageId: msgToPlay.id, originalFilename: msgToPlay.filename, tempFilenameBase: _tempAudioFilenameReceiverBase);
    String localFilePath = '${_receiverTempDirectoryPath!}/$localFileName';

    try {
      final response = await http.get(Uri.parse(msgToPlay.url));
      if (response.statusCode == 200) {
        final File file = File(localFilePath);
        await file.writeAsBytes(response.bodyBytes);
        if(mounted) setState(() => msgToPlay.localPath = localFilePath );
        if (!mounted) { setState(()=> _currentPlaybackFinishedOrError = true); return; }

        // El estado _isAudioMessageCurrentlyPlaying y _idOfMessageCurrentlyPlaying ya están seteados
        // Solo necesitamos que el message object tenga isPlaying = true
        if(mounted) setState(() => msgToPlay.isPlaying = true);

        await _audioHandlerService.playAudioFile( localFilePath, msgToPlay.id,
            onStarted: () { if(mounted && _idOfMessageCurrentlyPlaying == msgToPlay.id) setState(() => msgToPlay.isPlaying = true); },
            onCompleted: () {
              if (mounted) {
                setState(() {
                  msgToPlay.isPlaying = false; _currentPlaybackFinishedOrError = true;
                  if(_idOfMessageCurrentlyPlaying == msgToPlay.id){ _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null;}
                });
              }
            },
            onError: (e) {
              _showMessage("Error al reproducir: $e", isError: true);
              if (mounted) {
                setState(() {
                  msgToPlay.isPlaying = false; msgToPlay.hasError = true; _currentPlaybackFinishedOrError = true;
                  if(_idOfMessageCurrentlyPlaying == msgToPlay.id){_isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null;}
                });
              }
            }
        );
      } else { throw Exception('Fallo al descargar: ${response.statusCode}'); }
    } catch (e) {
      _showMessage("Error al descargar: $e", isError: true);
      if (mounted) { setState(() { msgToPlay.hasError = true; _currentPlaybackFinishedOrError = true; if(_idOfMessageCurrentlyPlaying == msgToPlay.id){_isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null;} }); }
    } finally {
      if (mounted) setState(() => msgToPlay.isDownloading = false);
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
    bool canConnect = username.trim().isNotEmpty && selectedServer != null && (_isMicPermissionGranted || kDebugMode) && audioSystemReady;

    if (connected) {
      if (_currentGlobalTransmitterId != null) {
        if (_currentGlobalTransmitterId == clientId) { channelStatusText = "TU TRANSMITES (SIM)"; channelStatusColor = Colors.redAccent.shade700; }
        else { channelStatusText = "EN CANAL: ${_currentGlobalTransmitterName ?? 'Desconocido'}"; channelStatusColor = Colors.orange.shade700; }
      } else if (_isAudioMessageCurrentlyPlaying && _idOfMessageCurrentlyPlaying != null && _lastReceivedMessageForAutoPlay?.id == _idOfMessageCurrentlyPlaying) {
        channelStatusText = "REPRODUCIENDO DE: ${_lastReceivedMessageForAutoPlay!.senderUsername}"; channelStatusColor = Colors.purple.shade400;
      }
    }

    // --- PTT Button Logic ---
    if (!connected) { /* No PTT button logic */ }
    else if (!_isMicPermissionGranted && kReleaseMode) { pttButtonText = "PERMISO MIC"; pttIcon = Icons.mic_off_rounded; pttButtonColor = Colors.red.shade300; }
    else if (!audioSystemReady) { pttButtonText = "AUDIO NO LISTO"; pttIcon = Icons.volume_off_rounded; pttButtonColor = Colors.blueGrey.shade300; }
    else {
      if (_isAudioMessageCurrentlyPlaying && _idOfMessageCurrentlyPlaying != null && !_currentPlaybackFinishedOrError) {
        // Si un audio se está reproduciendo activamente (y no ha terminado/error)
        pttButtonText = "REPRODUCIENDO...";
        // Cambiar icono a un círculo simple o icono de "no tocar"
        pttIcon = Icons.play_circle_fill_rounded; // O usa Icons.circle si quieres un círculo simple
        pttButtonColor = Colors.purple.shade300; // Un color que indique que está ocupado y no es PTT
        pttButtonEnabled = false; // No se puede interactuar como PTT
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
            // El Expanded ahora contiene un Column que centrará el botón PTT
            Expanded(
              child: connected
                  ? Column(
                mainAxisAlignment: MainAxisAlignment.center, // Centra el botón verticalmente
                crossAxisAlignment: CrossAxisAlignment.center, // Centra el botón horizontalmente
                children: [
                  GestureDetector(
                    onTapDown: pttButtonEnabled ? (_) => _onPttPress() : null,
                    onTapUp: pttButtonEnabled ? (_) => _onPttRelease() : null,
                    onLongPressStart: pttButtonEnabled ? (_) => _onPttPress() : null,
                    onLongPressEnd: pttButtonEnabled ? (_) => _onPttRelease() : null,
                    onLongPressCancel: pttButtonEnabled ? () => _onPttRelease() : null,
                    child: AnimatedContainer(
                        duration: Duration(milliseconds: 150),
                        padding: EdgeInsets.all(25), // Aumentar padding para hacerlo más grande
                        constraints: BoxConstraints(minWidth: 140, minHeight: 140, maxWidth: 180, maxHeight: 180), // Ajustar tamaño
                        decoration: BoxDecoration(
                          color: pttButtonColor, shape: BoxShape.circle,
                          boxShadow: [ if(pttButtonEnabled && !( _isAudioMessageCurrentlyPlaying && !_currentPlaybackFinishedOrError ) ) // No sombra si es el ícono de reproducción
                            BoxShadow(color: pttButtonColor.withOpacity(0.5), blurRadius: 10, spreadRadius: 3)
                          ],
                          border: _isAudioMessageCurrentlyPlaying && !_currentPlaybackFinishedOrError
                              ? Border.all(color: Colors.white54, width: 2) // Borde para el icono de reproducción
                              : null,
                        ),
                        child: Column( mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center,
                          children: [ Icon(pttIcon, size: 40, color: Colors.white), SizedBox(height: 5), Container( width: 90, child: Text( pttButtonText, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis ) ) ],
                        )
                    ),
                  ),
                  // Indicador de "Error al reproducir" se puede mostrar aquí si es necesario
                  if (_lastReceivedMessageForAutoPlay != null && _lastReceivedMessageForAutoPlay!.hasError && _currentPlaybackFinishedOrError)
                    Padding(
                      padding: const EdgeInsets.only(top: 20.0),
                      child: Text("Error al reproducir el último audio.", style: TextStyle(color: Colors.redAccent, fontStyle: FontStyle.italic)),
                    )
                ],
              )
                  : Center(child: Text( !_isMicPermissionGranted && kReleaseMode ? "Permiso de micrófono es necesario." : "Conéctate para usar la función PTT.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade700))),
            ),
          ],
        ),
      ),
    );
  }
}

