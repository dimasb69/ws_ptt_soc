import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'audio_handler.dart';

void main() {
  runApp(PTTApp());
}

class PTTApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PTT - Paso 2 (Sim Audio)',
      theme: ThemeData(
        primarySwatch: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: PTTHomePage(),
    );
  }
}

enum EmisorLocalPttStatus { idle, requesting, transmitting }

class PTTHomePage extends StatefulWidget {
  @override
  _PTTHomePageState createState() => _PTTHomePageState();
}

class _PTTHomePageState extends State<PTTHomePage> {
  final _uuid = Uuid();
  late String clientId;

  String username = "";
  List<String> servers = ["ws://192.168.100.26:8000/ws"];
  String? selectedServer;

  WebSocketChannel? channel;
  StreamSubscription? _websocketSubscription;
  bool connected = false;

  EmisorLocalPttStatus _emisorPttStatus = EmisorLocalPttStatus.idle;
  String? _currentGlobalTransmitterId;
  String? _currentGlobalTransmitterName;
  bool _isMicPermissionGranted = false;

  late AudioHandlerService _audioHandlerService;
  bool _isAudioHandlerReady = false;

  // --- Para Simulación de Audio Chunks ---
  Timer? _audioChunkTimer;
  int _audioChunkCounter = 0;
  bool _isReceivingAudioChunks = false; // Para UI del receptor
  // --- Fin Simulación ---

  String get _logPrefix => "[$clientId (${username.isNotEmpty ? username.substring(0,min(username.length,5)) : 'NO_USER'})]";

  @override
  void initState() {
    super.initState();
    clientId = _uuid.v4();
    if (servers.isNotEmpty) {
      selectedServer = servers.first;
    }
    _audioHandlerService = AudioHandlerService();
    _audioHandlerService.setClientIdForLogs(clientId);
    _initPermissionsAndAudio();
  }

  Future<void> _initPermissionsAndAudio() async {
    logPrint("PASO_2: Inicializando permisos y audio...");
    var micStatus = await Permission.microphone.request();
    bool micPermission = micStatus == PermissionStatus.granted;

    await _audioHandlerService.initAudio();

    if (mounted) {
      setState(() {
        _isMicPermissionGranted = micPermission;
        _isAudioHandlerReady = true;
      });
    }

    if (micPermission) {
      logPrint("PASO_2: Permiso de micrófono CONCEDIDO.");
    } else {
      logPrint("PASO_2: Permiso de micrófono DENEGADO.");
      _showMessage("Permiso de Micrófono Denegado.", isError: true, durationSeconds: 4);
    }
    logPrint("PASO_2: AudioHandlerService inicializado y listo para beeps.");
  }

  Future<void> _playLocalBeepInicio() async {
    if (!_isAudioHandlerReady || !mounted) return;
    logPrint("BEEP: Solicitando Beep INICIO local.");
    await _audioHandlerService.playBeep('assets/beep2.wav', 'LocalBeepInicio');
  }

  Future<void> _playLocalBeepFin() async {
    if (!_isAudioHandlerReady || !mounted) return;
    logPrint("BEEP: Solicitando Beep FIN local.");
    await _audioHandlerService.playBeep('assets/bepbep2.wav', 'LocalBeepFin');
  }

  // --- Funciones para Simulación de Audio Chunks ---
  void _startSendingAudioChunks() {
    if (_audioChunkTimer != null && _audioChunkTimer!.isActive) {
      logPrint("SIM_AUDIO: Timer de chunks ya activo.");
      return;
    }
    if (!connected || _emisorPttStatus != EmisorLocalPttStatus.transmitting) {
      logPrint("SIM_AUDIO: No se envían chunks, no conectado o no transmitiendo.");
      return;
    }

    _audioChunkCounter = 0;
    logPrint("SIM_AUDIO: Iniciando envío de chunks simulados...");
    _audioChunkTimer = Timer.periodic(Duration(milliseconds: 200), (timer) {
      if (!mounted || !connected || _emisorPttStatus != EmisorLocalPttStatus.transmitting) {
        _stopSendingAudioChunks(); // Detener si el estado cambia
        return;
      }
      final chunkMessage = {
        "type": "audio_chunk",
        "data": "sim_chunk_${clientId.substring(0,3)}_${_audioChunkCounter++}"
      };
      channel?.sink.add(jsonEncode(chunkMessage));
      logPrint("SIM_AUDIO: Enviado ${chunkMessage['data']}");
    });
  }

  void _stopSendingAudioChunks() {
    if (_audioChunkTimer != null && _audioChunkTimer!.isActive) {
      logPrint("SIM_AUDIO: Deteniendo envío de chunks simulados.");
      _audioChunkTimer!.cancel();
      _audioChunkTimer = null;
    }
    _audioChunkCounter = 0; // Reset counter
  }
  // --- Fin Simulación ---


  void logPrint(String message) {
    if (kDebugMode) {
      print("$_logPrefix $message");
    }
  }

  void _connect() {
    // ... (sin cambios)
    if (username.trim().isEmpty) { _showMessage("Ingresa un nombre.", isError: true); logPrint("CONEXION: Conexión fallida, nombre vacío."); return; }
    if (selectedServer == null || selectedServer!.isEmpty) { _showMessage("Selecciona un servidor.", isError: true); logPrint("CONEXION: Conexión fallida, servidor no seleccionado."); return; }
    if (!_isMicPermissionGranted && kReleaseMode) { _showMessage("Permiso de micrófono es necesario.", isError: true); logPrint("CONEXION: Conexión fallida, permiso mic no concedido (Release)."); return; }
    if (!_isAudioHandlerReady) { _showMessage("Sistema de audio para beeps no está listo.", isError: true); logPrint("CONEXION: Conexión fallida, AudioHandler no listo."); return; }
    if (connected) { logPrint("CONEXION: Ya conectado."); return; }
    final url = "$selectedServer/$clientId/$username";
    logPrint("CONEXION: Conectando a $url...");
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
      if(mounted) { setState(() { connected = true; _emisorPttStatus = EmisorLocalPttStatus.idle; _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null; _isReceivingAudioChunks = false; }); }
      _showMessage("Conectado como '$username'", durationSeconds: 2);
      _websocketSubscription = channel!.stream.listen(
            (message) { if (!mounted) return; _handleServerMessage(message); },
        onDone: () {
          if (!mounted || channel == null) { logPrint("CONEXION: WebSocket onDone, pero ya desconectado localmente o no montado."); return; }
          logPrint("CONEXION: WebSocket Desconectado (onDone disparado por el servidor).");
          _showMessage("Desconexión del servidor (onDone).", isError: true);
          if(mounted) { setState(() { connected = false; _emisorPttStatus = EmisorLocalPttStatus.idle; _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null; _stopSendingAudioChunks(); _isReceivingAudioChunks = false; }); }
        },
        onError: (error) {
          if (!mounted || channel == null) { logPrint("CONEXION: WebSocket onError, pero ya desconectado localmente o no montado."); return; }
          logPrint("CONEXION: WebSocket Error: $error");
          _showMessage("Error de conexión: $error", isError: true);
          if(mounted) { setState(() { connected = false; _emisorPttStatus = EmisorLocalPttStatus.idle; _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null; _stopSendingAudioChunks(); _isReceivingAudioChunks = false; }); }
        },
      );
    } catch (e) { logPrint("CONEXION: Excepción al conectar: $e"); _showMessage("Excepción al conectar: $e", isError: true); if(mounted) setState(() { connected = false; }); }
  }

  void _disconnect() {
    // ... (sin cambios, pero añadir _stopSendingAudioChunks)
    if (!connected && channel == null) { logPrint("CONEXION: Ya desconectado (o nunca conectado)."); return; }
    logPrint("CONEXION: Solicitando desconexión local...");
    _stopSendingAudioChunks(); // <<< DETENER TIMER AL DESCONECTAR
    if (mounted) { setState(() { connected = false; _emisorPttStatus = EmisorLocalPttStatus.idle; _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null; _isReceivingAudioChunks = false; }); }
    _showMessage("Desconectando...", durationSeconds: 1);
    _websocketSubscription?.cancel(); _websocketSubscription = null;
    channel?.sink.close().catchError((error) { logPrint("CONEXION: Error al cerrar sink del WebSocket: $error"); });
    channel = null;
    logPrint("CONEXION: Desconexión local completada.");
  }


  void _handleServerMessage(dynamic message) async {
    if (!mounted) return;
    try {
      final data = jsonDecode(message as String);
      final type = data['type'] as String?;
      logPrint("MSG_RECV: Tipo='$type', Data='$data'");

      switch (type) {
        case 'transmit_approved':
          if (_emisorPttStatus == EmisorLocalPttStatus.requesting) {
            logPrint("EMISOR: Recibido 'transmit_approved'.");
            if (_emisorPttStatus != EmisorLocalPttStatus.transmitting && mounted) {
              logPrint("EMISOR: 'transmit_approved' nos cambia a 'transmitting'. Reproduciendo beep.");
              setState(() { _emisorPttStatus = EmisorLocalPttStatus.transmitting; });
              await _playLocalBeepInicio();
              _startSendingAudioChunks(); // <<< INICIAR ENVÍO DE CHUNKS
            } else if (mounted) {
              logPrint("EMISOR: 'transmit_approved' recibido, pero ya estábamos 'transmitting'.");
            }
          } else { /* ... */ }
          break;

        case 'transmit_denied':
          logPrint("EMISOR: Recibido 'transmit_denied'. Razón: ${data['reason']}");
          _showMessage("No puedes transmitir: ${data['reason']}", isError: true, durationSeconds: 3);
          if(mounted) { if (_emisorPttStatus == EmisorLocalPttStatus.requesting) { setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; }); } }
          break;

        case 'transmit_started':
          final transmitterId = data['client_id'] as String?;
          final transmitterUsername = data['username'] as String?;
          logPrint("GLOBAL: Recibido 'transmit_started' de '$transmitterUsername' ($transmitterId).");

          bool amITheNewTransmitter = transmitterId == clientId;
          String? previousGlobalTransmitterId = _currentGlobalTransmitterId;

          if (mounted) {
            setState(() {
              _currentGlobalTransmitterId = transmitterId;
              _currentGlobalTransmitterName = transmitterUsername ?? 'Desconocido';
              if (!amITheNewTransmitter) _isReceivingAudioChunks = true; // Empezar a "recibir" si es otro
            });

            if (amITheNewTransmitter) {
              _showMessage("¡Estás transmitiendo!", durationSeconds: 1);
              if (_emisorPttStatus == EmisorLocalPttStatus.requesting) {
                logPrint("EMISOR: Mi 'transmit_started' recibido mientras 'requesting'. Cambiando a 'transmitting' Y REPRODUCIENDO BEEP.");
                setState(() => _emisorPttStatus = EmisorLocalPttStatus.transmitting);
                await _playLocalBeepInicio();
                _startSendingAudioChunks(); // <<< INICIAR ENVÍO DE CHUNKS
              }
            } else {
              _showMessage("${transmitterUsername ?? 'Alguien'} transmite...", durationSeconds: 2);
              if (previousGlobalTransmitterId == null) {
                logPrint("RECEPTOR: Canal estaba libre, '$transmitterUsername' inicia. Reproduciendo beep inicio.");
                await _playLocalBeepInicio();
              } else { /* ... */ }
            }
          }
          break;

        case 'transmit_stopped':
          final stopperId = data['client_id'] as String?;
          final stopperUsername = data['username'] as String?;
          logPrint("GLOBAL: Recibido 'transmit_stopped' (originado por $stopperId - $stopperUsername).");

          bool wasITheOneStopping = stopperId == clientId;
          bool wasSomeoneElseStopping = _currentGlobalTransmitterId != null && _currentGlobalTransmitterId == stopperId && !wasITheOneStopping;

          if (mounted) {
            setState(() {
              _currentGlobalTransmitterId = null;
              _currentGlobalTransmitterName = null;
              _isReceivingAudioChunks = false; // <<< DEJAR DE "RECIBIR"
              if (wasITheOneStopping && _emisorPttStatus == EmisorLocalPttStatus.transmitting) {
                // _stopSendingAudioChunks(); // _onPttRelease ya lo hace
                _emisorPttStatus = EmisorLocalPttStatus.idle;
              }
            });
          }
          _showMessage("Transmisión finalizada por ${stopperUsername ?? 'alguien'}.", durationSeconds: 1);
          if (wasSomeoneElseStopping) {
            await _playLocalBeepFin();
          }
          break;

      // --- NUEVO CASO PARA AUDIO CHUNKS ---
        case 'audio_chunk':
          final chunkSenderId = data['client_id'] as String?;
          final chunkSenderName = data['username'] as String?;
          final chunkData = data['data'] as String?;
          if (chunkSenderId != clientId) { // Si no soy yo el que envió el chunk
            logPrint("RECEPTOR: Recibido audio_chunk de '$chunkSenderName'. Data: '$chunkData'");
            if (mounted && !_isReceivingAudioChunks) { // Por si acaso el estado de UI se desincroniza
              setState(() { _isReceivingAudioChunks = true; });
            }
            // Aquí podríamos actualizar la UI del receptor para mostrar que está llegando audio.
            // Por ahora, solo log.
          }
          break;
      // --- FIN NUEVO CASO ---

        default:
          logPrint("WARN: Mensaje desconocido del servidor: tipo='$type'");
      }
    } catch (e, s) { logPrint("ERR: Error procesando mensaje del servidor: $e. Stack: $s. Mensaje: $message"); }
  }

  Future<void> _onPttPress() async {
    // ... (sin cambios)
    if (!connected) { _showMessage("No conectado.", isError: true); logPrint("WARN_PTT: Presionado pero no conectado."); return; }
    if (!_isMicPermissionGranted && kReleaseMode){ _showMessage("Permiso de micrófono es necesario.", isError: true); return; }
    if (!_isAudioHandlerReady) { _showMessage("Audio para beeps no listo.", isError: true); return; }
    if (_emisorPttStatus == EmisorLocalPttStatus.idle && _currentGlobalTransmitterId == null) {
      logPrint("PTT_PRESS: Solicitando transmisión (desde idle y canal libre).");
      if(mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.requesting; });
      channel?.sink.add(jsonEncode({"type": "request_transmit"}));
      _showMessage("Solicitando...", durationSeconds: 1);
    } else if (_currentGlobalTransmitterId != null && _currentGlobalTransmitterId != clientId) { _showMessage("${_currentGlobalTransmitterName ?? 'Alguien'} ya transmite.", isError: true); logPrint("WARN_PTT: Presionado pero ${_currentGlobalTransmitterName ?? 'alguien'} transmite.");
    } else if (_emisorPttStatus != EmisorLocalPttStatus.idle) { logPrint("INFO_PTT: PTT Presionado, pero mi estado local es ${_emisorPttStatus}.");
    } else if (_currentGlobalTransmitterId == clientId && _emisorPttStatus == EmisorLocalPttStatus.idle) { logPrint("WARN_PTT: PTT Presionado. Canal global dice que soy yo, pero mi estado local es idle. Re-solicitando."); if(mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.requesting; }); channel?.sink.add(jsonEncode({"type": "request_transmit"})); _showMessage("Re-solicitando...", durationSeconds: 1); }
  }

  Future<void> _onPttRelease() async {
    if (!connected || !_isAudioHandlerReady || !mounted ) return;

    if (_emisorPttStatus == EmisorLocalPttStatus.transmitting) {
      logPrint("PTT_RELEASE: Deteniendo mi transmisión (estaba transmitiendo).");
      _stopSendingAudioChunks(); // <<< DETENER ENVÍO DE CHUNKS
      await _audioHandlerService.cancelCurrentBeep();
      if (!mounted) return;
      await _playLocalBeepFin();
      if (!mounted) return;
      if(mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
      channel?.sink.add(jsonEncode({"type": "stop_transmit"}));
    } else if (_emisorPttStatus == EmisorLocalPttStatus.requesting) {
      logPrint("PTT_RELEASE: Soltado mientras solicitaba. Cancelando solicitud localmente.");
      // No necesitamos _stopSendingAudioChunks() aquí porque no debería haber empezado.
      await _audioHandlerService.cancelCurrentBeep();
      if (!mounted) return;
      if(mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
      _showMessage("Solicitud cancelada localmente.", durationSeconds: 1);
    } else { /* ... */ }
  }

  @override
  void dispose() {
    logPrint("DISPOSE: dispose() llamado.");
    _stopSendingAudioChunks(); // <<< DETENER TIMER AL DESTRUIR
    _websocketSubscription?.cancel(); _websocketSubscription = null;
    if(channel != null) { channel!.sink.close().catchError((e){ logPrint("Error al cerrar sink en dispose: $e");}); channel = null; }
    _audioHandlerService.dispose();
    super.dispose();
  }

  // _showMessage, _addServer, _removeServer (sin cambios)
  // ...
  void _showMessage(String msg, {bool isError = false, int? durationSeconds}) { if (mounted) { ScaffoldMessenger.of(context).removeCurrentSnackBar(); ScaffoldMessenger.of(context).showSnackBar( SnackBar( content: Text(msg), duration: Duration(seconds: durationSeconds ?? (isError ? 4 : 2)), backgroundColor: isError ? Colors.red.shade700 : Colors.teal.shade700, behavior: SnackBarBehavior.floating, ) ); } logPrint("UI_MSG: ($msg) ${isError ? "[ERROR]" : ""}"); }
  void _addServer() { showDialog(context: context, builder: (context) { final controller = TextEditingController(); return AlertDialog( title: Text("Agregar URL Servidor"), content: TextField(controller: controller, decoration: InputDecoration(hintText: "ws://ip:puerto/ws"), keyboardType: TextInputType.url), actions: [ TextButton(onPressed: () { final url = controller.text.trim(); if (url.isNotEmpty && (url.startsWith("ws://") || url.startsWith("wss://"))) { if (!servers.contains(url)) { if (mounted) setState(() { servers.add(url); selectedServer = url; }); _showMessage("Servidor '$url' añadido."); } else { _showMessage("Servidor ya existe.", isError: true); } } else { _showMessage("URL inválida.", isError: true); } Navigator.pop(context); }, child: Text("Agregar")), TextButton(onPressed: () => Navigator.pop(context), child: Text("Cancelar")), ], ); }); }
  void _removeServer(String url) { if (servers.length <= 1 && servers.contains(url)) { _showMessage("No puedes eliminar el único servidor.", isError: true); return; } if (mounted) { setState(() { servers.remove(url); if (selectedServer == url) selectedServer = servers.isNotEmpty ? servers.first : null; }); } _showMessage("Servidor '$url' eliminado."); }

  @override
  Widget build(BuildContext context) {
    String pttButtonText = "N/A";
    Color pttButtonColor = Colors.grey.shade400;
    IconData pttIcon = Icons.mic_rounded; // Default a mic
    bool pttButtonEnabled = false;
    String channelStatusText = "CANAL LIBRE";
    Color channelStatusColor = Colors.green.shade700;

    bool canConnect = username.trim().isNotEmpty &&
        selectedServer != null &&
        (_isMicPermissionGranted || kDebugMode) &&
        _isAudioHandlerReady;

    if (connected) {
      if (_currentGlobalTransmitterId != null) {
        if (_currentGlobalTransmitterId == clientId) { // Yo transmito
          channelStatusText = "TU TRANSMITES";
          channelStatusColor = Colors.redAccent.shade700;
        } else { // Otro transmite
          channelStatusText = "EN CANAL: ${_currentGlobalTransmitterName ?? 'Desconocido'}";
          channelStatusColor = Colors.orange.shade700;
          if (_isReceivingAudioChunks) { // Añadir indicador si recibo chunks
            channelStatusText += " (REC...)";
          }
        }
      }
    }


    if (!connected) {
      // No hay botón PTT, se muestra el de conexión.
    } else if (!_isMicPermissionGranted && kReleaseMode) {
      pttButtonText = "PERMISO MIC";
      pttIcon = Icons.mic_off_rounded;
      pttButtonColor = Colors.red.shade300;
      pttButtonEnabled = false;
    } else if (!_isAudioHandlerReady) {
      pttButtonText = "AUDIO BEEP NO LISTO";
      pttIcon = Icons.volume_off_rounded;
      pttButtonColor = Colors.blueGrey.shade300;
      pttButtonEnabled = false;
    } else {
      if (_emisorPttStatus == EmisorLocalPttStatus.requesting) {
        pttButtonText = "SOLICITANDO...";
        pttIcon = Icons.timer_outlined;
        pttButtonColor = Colors.blueGrey;
        pttButtonEnabled = true;
      } else if (_emisorPttStatus == EmisorLocalPttStatus.transmitting) {
        pttButtonText = "DEJAR DE HABLAR";
        pttIcon = Icons.mic_off_rounded;
        pttButtonColor = Colors.redAccent.shade700;
        pttButtonEnabled = true;
      } else if (_currentGlobalTransmitterId != null && _currentGlobalTransmitterId != clientId) {
        pttButtonText = "${_currentGlobalTransmitterName ?? 'Alguien'} HABLA";
        pttIcon = Icons.hearing_rounded; // Cambiado para indicar escucha
        if(_isReceivingAudioChunks) pttIcon = Icons.record_voice_over_rounded; // Icono diferente si hay chunks
        pttButtonColor = Colors.orangeAccent.shade700;
        pttButtonEnabled = false;
      } else {
        pttButtonText = "PULSA Y HABLA";
        pttIcon = Icons.mic_rounded;
        pttButtonColor = Colors.green.shade700;
        pttButtonEnabled = true;
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text("PTT - Paso 2 ${username.isNotEmpty ? '($username)' : ''}")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!connected) ...[
              TextField( decoration: InputDecoration(labelText: "Tu Nombre", border: OutlineInputBorder(), prefixIcon: Icon(Icons.person_outline)), onChanged: (val) { if(mounted) setState(() => username = val.trim()); }, enabled: !connected, ),
              SizedBox(height: 8), Text("Servidor:", style: Theme.of(context).textTheme.bodySmall),
              Row(children: [ Expanded(child: DropdownButtonHideUnderline(child: Container( padding: EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0), decoration: BoxDecoration(borderRadius: BorderRadius.circular(8.0), border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.7), width: 1)), child: DropdownButton<String>( value: selectedServer, items: servers.isEmpty ? [DropdownMenuItem(value: null, enabled: false, child: Text("Añade un servidor", style: TextStyle(color: Colors.grey)))] : servers.map((s) => DropdownMenuItem(value: s, child: Row( mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [ Flexible(child: Text(s, overflow: TextOverflow.ellipsis)), if (!(servers.length == 1 && selectedServer == s)) IconButton(icon: Icon(Icons.delete_outline_rounded, color: Colors.red.shade400, size: 20), onPressed: () => _removeServer(s), padding: EdgeInsets.zero, constraints: BoxConstraints(), splashRadius: 20) ], ))).toList(), onChanged: (val) { if (mounted) setState(() { selectedServer = val; }); }, isExpanded: true, hint: Text("Selecciona o añade"), underline: SizedBox.shrink(), borderRadius: BorderRadius.circular(8.0), ), ))), IconButton(icon: Icon(Icons.add_circle_outline_rounded, color: Theme.of(context).colorScheme.primary), tooltip: "Añadir servidor", onPressed: _addServer) ]),
              SizedBox(height: 12), ElevatedButton.icon( icon: Icon(Icons.login_rounded), onPressed: canConnect ? _connect : null, label: Text("CONECTAR AL SERVIDOR"), style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, padding: EdgeInsets.symmetric(vertical: 14)) ),
              if (!_isAudioHandlerReady && _isMicPermissionGranted) Padding( padding: const EdgeInsets.only(top:8.0), child: Text("Inicializando audio para beeps...", textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: Colors.grey)), ),
              if (!_isMicPermissionGranted && kDebugMode) Padding( padding: const EdgeInsets.only(top:8.0), child: Text("Modo Debug: Conexión permitida sin permiso mic.", textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: Colors.grey)), ),
              SizedBox(height: 10),
            ] else ...[
              Text("Conectado como: $username", textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold)),
              Text("Servidor: $selectedServer", textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Text( channelStatusText, textAlign: TextAlign.center, style: TextStyle(color: channelStatusColor, fontStyle: FontStyle.italic, fontWeight: FontWeight.bold ) )
              ),
              SizedBox(height: 8), ElevatedButton.icon( icon: Icon(Icons.logout_rounded), onPressed: _disconnect, label: Text("DESCONECTAR"), style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey, padding: EdgeInsets.symmetric(vertical: 10)) ),
            ],
            Divider(height: 20, thickness: 1),
            if (connected)
              Expanded(
                child: Column( mainAxisAlignment: MainAxisAlignment.center, children: [
                  GestureDetector(
                    onTapDown: pttButtonEnabled ? (_) => _onPttPress() : null,
                    onTapUp: pttButtonEnabled ? (_) => _onPttRelease() : null,
                    onLongPressStart: pttButtonEnabled ? (_) => _onPttPress() : null,
                    onLongPressEnd: pttButtonEnabled ? (_) => _onPttRelease() : null,
                    onLongPressCancel: pttButtonEnabled ? () => _onPttRelease() : null,
                    child: AnimatedContainer( duration: Duration(milliseconds: 150), padding: EdgeInsets.all(15), constraints: BoxConstraints(minWidth: 130, minHeight: 130, maxWidth: 160, maxHeight: 160),
                        decoration: BoxDecoration( color: pttButtonEnabled ? pttButtonColor : Colors.grey.shade300, shape: BoxShape.circle, boxShadow: [ if(pttButtonEnabled) BoxShadow( color: pttButtonColor.withOpacity(0.5), blurRadius: 10, spreadRadius: 3, ) ], ),
                        child: Column( mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [ Icon(pttIcon, size: 35, color: Colors.white), SizedBox(height: 4), Container( width: 90, child: Text( pttButtonText, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, ), ), ], )
                    ),
                  ),
                ],
                ),
              )
            else if (!connected && _isMicPermissionGranted && _isAudioHandlerReady)
              Expanded(child: Center(child: Text("Conéctate para usar PTT", style: TextStyle(fontSize: 16, color: Colors.grey.shade700))))
            else
              Expanded(child: Center(child: Text( !_isMicPermissionGranted ? "Se requiere permiso de micrófono." : (_isAudioHandlerReady ? "Permiso de micrófono pendiente." : "Inicializando sistema de audio..."), textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Colors.red.shade700)))),
            if (!_isMicPermissionGranted && !connected) Padding( padding: const EdgeInsets.only(top: 10.0, bottom: 10.0), child: Text( "Se requiere permiso de micrófono para la funcionalidad PTT.", textAlign: TextAlign.center, style: TextStyle(color: Colors.red.shade700, fontSize: 12), ), ),
          ],
        ),
      ),
    );
  }
}

