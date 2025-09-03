import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

import 'package:another_audio_recorder/another_audio_recorder.dart';

import 'audio_handler.dart';
import 'config/app_theme.dart';
import 'utils/app_utils.dart';

const String _anotherRecorderTempFilename = "ptt_audio_record";
const AudioFormat _anotherRecorderAudioFormat = AudioFormat.AAC;
const String _anotherRecorderContentType = "audio/aac";
const String _anotherRecorderFileExtension = "m4a";

const String _tempAudioFilenameReceiverBase = "ptt_rcv_playback";

void main() {
  runApp(PTTApp());
}

class PTTApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'W-S PTT PoC',
      theme: getAppTheme(),
      darkTheme: getAppTheme(),
      themeMode: ThemeMode.dark,
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
  final TextEditingController _usernameController = TextEditingController();
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
  bool _isAudioHandlerServiceReady = false;

  ReceivedAudioMessage? _lastReceivedMessageForAutoPlay;
  String? _appTempDirectoryPath;
  bool _isAudioMessageCurrentlyPlaying = false;
  String? _idOfMessageCurrentlyPlaying;
  bool _currentPlaybackFinishedOrError = true;

  AnotherAudioRecorder? _audioRecorderInstance;
  RecordingStatus _currentRecorderStatus = RecordingStatus.Unset;
  String? _completeRecordingPath;
  bool _isAnotherRecorderReady = false;

  @override
  void initState() {
    super.initState();
    clientId = _uuid.v4();
    _usernameController.text = username;

    if (servers.isNotEmpty) selectedServer = servers.first;
    _audioHandlerService = AudioHandlerService();
    _initPermissionsAndAudio();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    if (_audioRecorderInstance != null && _currentRecorderStatus == RecordingStatus.Recording ) {
      _audioRecorderInstance!.stop().catchError((e){ if (kDebugMode) print("WARN: Error deteniendo AAR en dispose: $e");});
    }
    _audioRecorderInstance = null;
    _audioHandlerService.stopCurrentMessagePlayback();
    _websocketSubscription?.cancel();
    if(channel != null) { channel!.sink.close().catchError((e){/* ignorar */}); }
    _audioHandlerService.dispose();
    super.dispose();
  }

  Future<void> _initPermissionsAndAudio() async {
    var micStatus = await Permission.microphone.request();
    _isMicPermissionGranted = micStatus == PermissionStatus.granted;

    await _audioHandlerService.initAudio();
    if(mounted) setState(() => _isAudioHandlerServiceReady = true);

    if (_isMicPermissionGranted) {
      await _initializeAnotherRecorder();
    } else {
      if(mounted) showAppMessage(context, "Permiso de Micrófono denegado. Grabación PTT no disponible.", isError: true, durationSeconds: 5);
    }
  }

  Future<void> _initializeAnotherRecorder() async {
    if (!_isMicPermissionGranted) {
      if(mounted) setState(() => _isAnotherRecorderReady = false);
      return;
    }
    try {
      final directory = await getTemporaryDirectory();
      _appTempDirectoryPath = directory.path;
      _completeRecordingPath = '$_appTempDirectoryPath/$_anotherRecorderTempFilename.$_anotherRecorderFileExtension';

      try {
        final f = io.File(_completeRecordingPath!);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (e) {
        if (kDebugMode) print("WARN: No se pudo eliminar archivo de grabación previo: $e");
      }

      _audioRecorderInstance = AnotherAudioRecorder(_completeRecordingPath!, audioFormat: _anotherRecorderAudioFormat);
      await _audioRecorderInstance!.initialized;

      var currentStatus = await _audioRecorderInstance!.current(channel: 0);
      if (mounted) {
        setState(() {
          _currentRecorderStatus = currentStatus?.status ?? RecordingStatus.Unset;
          _isAnotherRecorderReady = (_currentRecorderStatus == RecordingStatus.Initialized ||
              _currentRecorderStatus == RecordingStatus.Stopped ||
              _currentRecorderStatus == RecordingStatus.Unset);
        });
      }
    } catch (e) {
      if (kDebugMode) print("ERROR: Inicializando AnotherAudioRecorder: $e");
      if (mounted) showAppMessage(context, "Error al inicializar grabador (AAR): $e", isError: true);
      if(mounted) setState(() => _isAnotherRecorderReady = false);
    }
  }

  Future<void> _playLocalBeepInicio() async {
    if (!_isAudioHandlerServiceReady || !mounted) return;
    await _audioHandlerService.playBeep('assets/beep2.wav', 'LocalBeepInicio');
  }

  Future<void> _playLocalBeepFin() async {
    if (!_isAudioHandlerServiceReady || !mounted) return;
    await _audioHandlerService.playBeep('assets/bepbep2.wav', 'LocalBeepFin');
  }

  Future<void> _startRecording() async {
    if (_audioRecorderInstance == null || !_isAnotherRecorderReady) {
      await _initializeAnotherRecorder();
      if (!_isAnotherRecorderReady) {
        if (mounted && _emisorPttStatus == EmisorLocalPttStatus.transmitting) {
          channel?.sink.add(jsonEncode({"type": "stop_transmit"}));
          if(mounted) setState(() => _emisorPttStatus = EmisorLocalPttStatus.idle);
        }
        return;
      }
    }

    if (_currentRecorderStatus == RecordingStatus.Recording) return;

    try {
      if (_currentRecorderStatus == RecordingStatus.Stopped || _currentRecorderStatus == RecordingStatus.Unset || _currentRecorderStatus == RecordingStatus.Initialized) {
        try {
          final f = io.File(_completeRecordingPath!);
          if (await f.exists()) await f.delete();
        } catch (e) { /* ignorar */ }
        _audioRecorderInstance = AnotherAudioRecorder(_completeRecordingPath!, audioFormat: _anotherRecorderAudioFormat);
        await _audioRecorderInstance!.initialized;
      }

      await _audioRecorderInstance!.start();
      var newStatus = await _audioRecorderInstance!.current(channel: 0);
      if (mounted) {
        setState(() {
          _currentRecorderStatus = newStatus?.status ?? RecordingStatus.Unset;
        });
      }
    } catch (e) {
      if (kDebugMode) print("ERROR: Iniciando grabación AAR: $e");
      if (mounted) {
        showAppMessage(context, "Error al iniciar grabación (AAR): $e", isError: true);
        if (_emisorPttStatus == EmisorLocalPttStatus.transmitting) {
          channel?.sink.add(jsonEncode({"type": "stop_transmit"}));
        }
        setState(() => _emisorPttStatus = EmisorLocalPttStatus.idle);
      }
    }
  }

  Future<String?> _stopRecording() async {
    if (_audioRecorderInstance == null || _currentRecorderStatus != RecordingStatus.Recording) {
      return null;
    }

    try {
      Recording? recordingResult = await _audioRecorderInstance!.stop();
      String? filePath = recordingResult?.path;
      if (mounted) {
        setState(() {
          _currentRecorderStatus = recordingResult?.status ?? RecordingStatus.Unset;
        });
      }

      if (filePath != null && filePath.isNotEmpty && await io.File(filePath).exists()) {
        if (await io.File(filePath).length() > 0) {
          return filePath;
        } else {
          if(mounted) showAppMessage(context, "Error: Archivo de grabación está vacío.", isError: true);
          return null;
        }
      } else {
        if (_completeRecordingPath != null && await io.File(_completeRecordingPath!).exists() && (await io.File(_completeRecordingPath!).length() > 0)) {
          return _completeRecordingPath;
        }
        if(mounted) showAppMessage(context, "Error: Archivo de grabación no encontrado tras detener.", isError: true);
        return null;
      }
    } catch (e) {
      if (kDebugMode) print("ERROR: Deteniendo grabación AAR: $e");
      if(mounted) showAppMessage(context, "Error al detener grabación (AAR): $e", isError: true);
      return null;
    }
  }

  Future<void> _sendRecordedAudioFileAndNotifyStop(String filePath) async {
    if (!connected || channel == null) {
      if (mounted && _emisorPttStatus == EmisorLocalPttStatus.transmitting) {
        setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
      }
      return;
    }
    final String filenameForServer = "rec_aar_${clientId.substring(0, 4)}_${DateTime.now().millisecondsSinceEpoch}.$_anotherRecorderFileExtension";
    try {
      io.File audioFile = io.File(filePath);
      if (!await audioFile.exists()) {
        if(mounted) showAppMessage(context, "Error interno: Archivo de grabación no existe para envío.", isError: true);
        channel!.sink.add(jsonEncode({"type": "stop_transmit"}));
        return;
      }
      final Uint8List fileBytes = await audioFile.readAsBytes();
      if (fileBytes.isEmpty) {
        if(mounted) showAppMessage(context, "Error: Grabación resultó vacía, no se enviará.", isError: true);
        channel!.sink.add(jsonEncode({"type": "stop_transmit"}));
        return;
      }
      final String base64AudioData = base64Encode(fileBytes);
      final message = {
        "type": "new_audio_message",
        "filename": filenameForServer,
        "content_type": _anotherRecorderContentType,
        "data": base64AudioData
      };
      channel!.sink.add(jsonEncode(message));
      try {
        await audioFile.delete();
      } catch (e) {
        if (kDebugMode) print("WARN: Error eliminando archivo local $filePath: $e");
      }
    } catch (e) {
      if (kDebugMode) print("ERROR: Enviando audio: $e");
      if(mounted) showAppMessage(context, "Error al enviar audio: $e", isError: true);
    } finally {
      if (connected && channel != null) {
        channel!.sink.add(jsonEncode({"type": "stop_transmit"}));
      }
    }
  }

  void _connect() {
    if (mounted) {
      setState(() {
        username = _usernameController.text.trim();
      });
    }

    bool canAttemptConnect = username.isNotEmpty &&
        selectedServer != null &&
        selectedServer!.isNotEmpty &&
        _isAudioHandlerServiceReady &&
        _isAnotherRecorderReady &&
        !connected;

    if ((!_isMicPermissionGranted && kReleaseMode) && !_isAnotherRecorderReady) {
      showAppMessage(context, "Permiso de Micrófono y grabador no listos.", isError: true); return;
    }
    if (!_isMicPermissionGranted && kReleaseMode) {
      showAppMessage(context, "Permiso de Micrófono es necesario para grabar.", isError: true); return;
    }
    if (!_isAnotherRecorderReady) {
      showAppMessage(context, "El sistema de grabación (AAR) no está listo. Intenta de nuevo.", isError: true); return;
    }

    if (!canAttemptConnect) {
      if(username.isEmpty && mounted) showAppMessage(context, "Por favor, ingresa tu nombre.", isError: true);
      return;
    }

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
      showAppMessage(context, "Conectado como '$username'", durationSeconds: 2);

      _websocketSubscription = channel!.stream.listen(
            (message) { if (!mounted) return; _handleServerMessage(message); },
        onDone: () {
          if (!mounted || channel == null) return;
          showAppMessage(context, "Desconexión del servidor.", isError: true);
          _audioHandlerService.stopCurrentMessagePlayback();
          if (_audioRecorderInstance != null && _currentRecorderStatus == RecordingStatus.Recording) { _stopRecording(); }
          if(mounted) { setState(() { connected = false; _emisorPttStatus = EmisorLocalPttStatus.idle; _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null; _lastReceivedMessageForAutoPlay = null; _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null; _currentPlaybackFinishedOrError = true; }); }
        },
        onError: (error) {
          if (kDebugMode) print("ERROR: WebSocket: $error");
          if (!mounted || channel == null) return;
          showAppMessage(context, "Error de conexión: $error", isError: true);
          _audioHandlerService.stopCurrentMessagePlayback();
          if (_audioRecorderInstance != null && _currentRecorderStatus == RecordingStatus.Recording) { _stopRecording(); }
          if(mounted) { setState(() { connected = false; _emisorPttStatus = EmisorLocalPttStatus.idle; _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null; _lastReceivedMessageForAutoPlay = null; _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null; _currentPlaybackFinishedOrError = true; }); }
        },
      );
    } catch (e) {
      if (kDebugMode) print("ERROR: Conectando WebSocket: $e");
      showAppMessage(context, "Excepción al conectar: $e", isError: true);
      if(mounted) setState(() { connected = false; });
    }
  }

  Future<void> _disconnect() async {
    if (!connected && channel == null) return;

    final bool? confirmDisconnect = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text('Confirmar Desconexión'),
          content: Text('¿Estás seguro de que quieres desconectarte?'),
          actions: <Widget>[
            TextButton(
              child: Text('Cancelar'),
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
            ),
            TextButton(
              child: Text('Desconectar', style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
            ),
          ],
        );
      },
    );

    if (confirmDisconnect == true) {
      if (_audioRecorderInstance != null && _currentRecorderStatus == RecordingStatus.Recording) {
        _stopRecording().catchError((e) { if (kDebugMode) print("WARN: Error deteniendo grabador en disconnect: $e"); });
      }
      _audioHandlerService.stopCurrentMessagePlayback();
      if (mounted) {
        setState(() {
          connected = false;
          _emisorPttStatus = EmisorLocalPttStatus.idle;
          _currentGlobalTransmitterId = null;
          _currentGlobalTransmitterName = null;
          _lastReceivedMessageForAutoPlay = null;
          _isAudioMessageCurrentlyPlaying = false;
          _idOfMessageCurrentlyPlaying = null;
          _currentPlaybackFinishedOrError = true;
        });
      }
      showAppMessage(context, "Desconectando...", durationSeconds: 1);
      _websocketSubscription?.cancel(); _websocketSubscription = null;
      channel?.sink.close().catchError((e) {/* ignorar */}); channel = null;
    }
  }

  void _handleAddNewServer() {
    showAddServerDialog(
        context: context,
        showMessageCallback: (msg, {isError = false}) {
          showAppMessage(context, msg, isError: isError);
        },
        onServerAdded: (newUrl) {
          if (!servers.contains(newUrl)) {
            if (mounted) {
              setState(() {
                servers.add(newUrl);
                selectedServer = newUrl;
              });
            }
            showAppMessage(context, "Servidor '$newUrl' añadido.");
          } else {
            showAppMessage(context, "Servidor ya existe.", isError: true);
          }
        }
    );
  }

  void _handleRemoveServer(String urlToRemove) {
    final result = prepareServerRemoval(
        currentServers: servers,
        currentSelectedServer: selectedServer,
        urlToRemove: urlToRemove,
        showMessageCallback: (msg, {isError = false}) {
          showAppMessage(context, msg, isError: isError);
        }
    );

    if (result['removed'] == true && mounted) {
      setState(() {
        servers = result['servers'];
        selectedServer = result['selectedServer'];
      });
    }
  }

  void _handleServerMessage(dynamic rawMessage) async {
    if (!mounted) return;
    try {
      final data = jsonDecode(rawMessage as String);
      final type = data['type'] as String?;

      switch (type) {
        case 'transmit_approved':
          if (mounted && _emisorPttStatus == EmisorLocalPttStatus.requesting) {
            if(mounted) setState(() => _emisorPttStatus = EmisorLocalPttStatus.transmitting );
            Future.delayed(Duration(milliseconds: 50), () async {
              if (!mounted || _emisorPttStatus != EmisorLocalPttStatus.transmitting) return;
              await _playLocalBeepInicio();
              await _startRecording();
              if (mounted) showAppMessage(context, "Grabando...", durationSeconds: 2);
            });
          }
          break;
        case 'transmit_denied':
          showAppMessage(context, "No puedes enviar: ${data['reason']}", isError: true);
          if(mounted && _emisorPttStatus == EmisorLocalPttStatus.requesting) {
            if(mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
            await _playLocalBeepFin();
          }
          break;
        case 'transmit_started':
          final tId = data['client_id'] as String?;
          final tName = data['username'] as String?;
          bool isMe = tId == clientId;
          String? prevId = _currentGlobalTransmitterId;

          if (mounted) {
            setState(() { _currentGlobalTransmitterId = tId; _currentGlobalTransmitterName = tName ?? 'Desconocido'; });
            if (isMe) {
              if (_emisorPttStatus == EmisorLocalPttStatus.transmitting) {
                showAppMessage(context, "Canal abierto. Estás grabando.", durationSeconds: 2);
              } else {
                if(mounted) setState(() => _emisorPttStatus = EmisorLocalPttStatus.transmitting);
                showAppMessage(context, "Canal abierto (estado local corregido).", durationSeconds: 2);
              }
            } else {
              showAppMessage(context, "${tName ?? 'Alguien'} está grabando...", durationSeconds: 2);
              if (prevId == null && !_isAudioMessageCurrentlyPlaying) {
                await _playLocalBeepInicio();
              }
            }
          }
          break;
        case 'transmit_stopped':
          final sId = data['client_id'] as String?;
          final sName = data['username'] as String?;
          bool wasMe = sId == clientId;
          bool wasOther = _currentGlobalTransmitterId != null && _currentGlobalTransmitterId == sId && !wasMe;

          if (mounted) {
            if (_currentGlobalTransmitterId == sId) {
              if(mounted) setState(() { _currentGlobalTransmitterId = null; _currentGlobalTransmitterName = null; });
            }
            if (wasMe && (_emisorPttStatus == EmisorLocalPttStatus.transmitting || _emisorPttStatus == EmisorLocalPttStatus.requesting)) {
              if(mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
            }
          }

          if (wasOther) {
            showAppMessage(context, "Grabación de ${sName ?? 'alguien'} finalizada.", durationSeconds: 1);
            final bool isCurrentlyPlayingAudioFromThisSender =
                _isAudioMessageCurrentlyPlaying &&
                    _idOfMessageCurrentlyPlaying != null &&
                    _lastReceivedMessageForAutoPlay?.senderUsername == sName &&
                    _lastReceivedMessageForAutoPlay?.id == _idOfMessageCurrentlyPlaying;
            if (!isCurrentlyPlayingAudioFromThisSender) {
              await _playLocalBeepFin();
            }
          }
          else if (wasMe) {
            showAppMessage(context, "Tu transmisión ha finalizado.", durationSeconds: 1);
          }
          break;
        case 'incoming_audio_message':
          final mId = data['message_id'] as String?;
          final scId = data['sender_client_id'] as String?;
          final suName = data['sender_username'] as String?;
          final fName = data['filename'] as String?;
          final audioUrl = buildAudioDownloadUrl(selectedServerUrl: selectedServer, messageId: mId, filenameFromServer: fName);

          if (mId != null && scId != null && suName != null && fName != null && audioUrl != null && scId != clientId) {
            final newMsg = ReceivedAudioMessage(id: mId, senderUsername: suName, filename: fName, url: audioUrl);
            if (mounted) {
              if (_isAudioMessageCurrentlyPlaying && _idOfMessageCurrentlyPlaying != newMsg.id) {
                await _audioHandlerService.stopCurrentMessagePlayback();
                if(mounted) {
                  setState(() {
                    if (_lastReceivedMessageForAutoPlay?.id == _idOfMessageCurrentlyPlaying) {
                      if (_lastReceivedMessageForAutoPlay != null) _lastReceivedMessageForAutoPlay!.isPlaying = false;
                    }
                    _isAudioMessageCurrentlyPlaying = false; _idOfMessageCurrentlyPlaying = null;
                    _currentPlaybackFinishedOrError = true;
                  });
                }
                await Future.delayed(Duration(milliseconds: 150));
              }
              if(mounted) {
                setState(() { _lastReceivedMessageForAutoPlay = newMsg; _currentPlaybackFinishedOrError = false; });
              }
              if (_lastReceivedMessageForAutoPlay != null) {
                showAppMessage(context, "Audio de $suName. Reproduciendo...", durationSeconds: 2);
                _downloadAndPlayReceivedAudio(_lastReceivedMessageForAutoPlay!);
              }
            }
          }
          break;
        default:
          if (kDebugMode) print("WARN: Tipo de mensaje desconocido: $type, Data: $data");
          break;
      }
    } catch (e, s) {
      if (kDebugMode) print("ERROR: Manejando mensaje del servidor: $e\nStackTrace: $s\nMensaje crudo: $rawMessage");
    }
  }

  Future<void> _onPttPress() async {
    bool canRequest = connected &&
        _isAudioHandlerServiceReady &&
        _isAnotherRecorderReady &&
        !_isAudioMessageCurrentlyPlaying &&
        (_currentGlobalTransmitterId == null) &&
        _emisorPttStatus == EmisorLocalPttStatus.idle;

    if (!canRequest) return;
    if (!_isMicPermissionGranted && kReleaseMode) {
      showAppMessage(context, "Permiso de micrófono es necesario para grabar.", isError: true); return;
    }
    if(mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.requesting; });
    channel?.sink.add(jsonEncode({"type": "request_transmit"}));
    showAppMessage(context, "Solicitando para grabar...", durationSeconds: 1);
  }

  Future<void> _onPttRelease() async {
    if (!connected || !_isAudioHandlerServiceReady || !_isAnotherRecorderReady ) return;

    if (_emisorPttStatus == EmisorLocalPttStatus.transmitting) {
      final String? recordedFilePath = await _stopRecording();
      if (mounted) await _playLocalBeepFin();
      if (!mounted) return;

      if (recordedFilePath != null) {
        await _sendRecordedAudioFileAndNotifyStop(recordedFilePath);
      } else {
        showAppMessage(context, "Error: No se pudo obtener archivo grabado.", isError: true);
        if (connected && channel != null) {
          channel!.sink.add(jsonEncode({"type": "stop_transmit"}));
        }
      }
    } else if (_emisorPttStatus == EmisorLocalPttStatus.requesting) {
      await _audioHandlerService.cancelCurrentBeep();
      if(mounted) setState(() { _emisorPttStatus = EmisorLocalPttStatus.idle; });
      showAppMessage(context, "Solicitud cancelada.", durationSeconds: 1);
      await _playLocalBeepFin();
    }
  }

  Future<void> _downloadAndPlayReceivedAudio(ReceivedAudioMessage msgToPlay) async {
    if (kDebugMode) print("DL_PLAY: Iniciando para msg ID ${msgToPlay.id}. URL: ${msgToPlay.url}");

    if (_appTempDirectoryPath == null) {
      showAppMessage(context, "Directorio temporal no listo.", isError: true);
      if (kDebugMode) print("DL_PLAY_ERR: _appTempDirectoryPath es nulo para msg ID ${msgToPlay.id}.");
      if (mounted) setState(()=> _currentPlaybackFinishedOrError = true);
      return;
    }

    if (connected && channel != null) {
      channel!.sink.add(jsonEncode({ "type": "receiver_busy", "client_id": clientId, "message_id": msgToPlay.id }));
    }

    if(mounted) {
      setState(() {
        msgToPlay.isDownloading = true; msgToPlay.hasError = false;
        _isAudioMessageCurrentlyPlaying = true; _idOfMessageCurrentlyPlaying = msgToPlay.id;
        _currentPlaybackFinishedOrError = false;
      });
    }

    String localFileName = generateLocalFilenameForDownload(messageId: msgToPlay.id, originalFilename: msgToPlay.filename, tempFilenameBase: _tempAudioFilenameReceiverBase);
    String localFilePath = '${_appTempDirectoryPath!}/$localFileName';
    if (kDebugMode) print("DL_PLAY: Preparado localFilePath: $localFilePath para msg ID ${msgToPlay.id}");

    try {
      if (kDebugMode) print("DL_PLAY: Intentando http.get para ${msgToPlay.url} (Msg ID: ${msgToPlay.id})");
      final response = await http.get(Uri.parse(msgToPlay.url));
      if (kDebugMode) print("DL_PLAY: http.get completado para ${msgToPlay.id}. Status: ${response.statusCode}");

      if (response.statusCode == 200) {
        final io.File file = io.File(localFilePath);
        await file.writeAsBytes(response.bodyBytes);
        if(mounted) setState(() => msgToPlay.localPath = localFilePath );

        if (!mounted) {
          if (connected && channel != null) channel!.sink.add(jsonEncode({"type": "receiver_ready", "client_id": clientId, "message_id": msgToPlay.id, "status": "aborted_not_mounted"}));
          return;
        }

        if(mounted) setState(() => msgToPlay.isPlaying = true);

        await _audioHandlerService.playAudioFile( localFilePath, msgToPlay.id,
            onStarted: () {
              if(mounted && _idOfMessageCurrentlyPlaying == msgToPlay.id) setState(() => msgToPlay.isPlaying = true);
            },
            onCompleted: () {
              if (mounted) {
                setState(() {
                  msgToPlay.isPlaying = false;
                  if(_idOfMessageCurrentlyPlaying == msgToPlay.id){
                    _isAudioMessageCurrentlyPlaying = false;
                    _idOfMessageCurrentlyPlaying = null;
                    _currentPlaybackFinishedOrError = true;
                  }
                });
                _playLocalBeepFin();
              }
            },
            onError: (e) {
              showAppMessage(context, "Error al reproducir: $e", isError: true);
              if (mounted) {
                setState(() {
                  msgToPlay.isPlaying = false; msgToPlay.hasError = true;
                  if(_idOfMessageCurrentlyPlaying == msgToPlay.id){
                    _isAudioMessageCurrentlyPlaying = false;
                    _idOfMessageCurrentlyPlaying = null;
                    _currentPlaybackFinishedOrError = true;
                  }
                });
                _playLocalBeepFin();
              }
            }
        );
      } else {
        if (kDebugMode) print("DL_PLAY_ERR: Fallo al descargar. Status: ${response.statusCode}. URL: ${msgToPlay.url} (Msg ID: ${msgToPlay.id})");
        throw Exception('Fallo al descargar: ${response.statusCode}');
      }
    } catch (e, s) {
      if (kDebugMode) print("DL_PLAY_ERR: Excepción en _downloadAndPlayReceivedAudio para msg ID ${msgToPlay.id}: $e\nStackTrace: $s");
      showAppMessage(context, "Error al descargar/procesar: $e", isError: true);
      if (mounted) {
        setState(() {
          msgToPlay.hasError = true;
          if(_idOfMessageCurrentlyPlaying == msgToPlay.id){
            _isAudioMessageCurrentlyPlaying = false;
            _idOfMessageCurrentlyPlaying = null;
            _currentPlaybackFinishedOrError = true;
          }
        });
        _playLocalBeepFin();
      }
    } finally {
      if (mounted) {
        setState(() => msgToPlay.isDownloading = false);
      }
      if (connected && channel != null) {
        String finalStatus = "error";
        if (mounted && _idOfMessageCurrentlyPlaying == null && _currentPlaybackFinishedOrError && !msgToPlay.hasError) {
          finalStatus = "completed";
        } else if (mounted && _isAudioMessageCurrentlyPlaying && _idOfMessageCurrentlyPlaying == msgToPlay.id && !msgToPlay.hasError) {
          finalStatus = "playing_interrupted";
        }
        channel!.sink.add(jsonEncode({ "type": "receiver_ready", "client_id": clientId, "message_id": msgToPlay.id, "status": finalStatus }));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    String pttButtonText = "";
    Color pttButtonColorValue;
    IconData pttIcon = Icons.mic;
    bool pttButtonEnabled = false;
    String channelStatusText = "CANAL LIBRE";
    Color channelStatusColorValue;

    Color appBarDynamicColorValue = appBarBackgroundColor;

    bool isActuallyRecording = _emisorPttStatus == EmisorLocalPttStatus.transmitting &&
        _currentRecorderStatus == RecordingStatus.Recording &&
        connected;

    if (isActuallyRecording) {
      appBarDynamicColorValue = pttButtonRecordingColor;
    } else if (connected && _currentGlobalTransmitterId != null && _currentGlobalTransmitterId != clientId) {
      appBarDynamicColorValue = channelStatusOtherRecordingColor;
    }

    bool micAndServicesReady = _isMicPermissionGranted &&
        _isAudioHandlerServiceReady &&
        _isAnotherRecorderReady;

    bool canConnectButtonEnabled = _usernameController.text.trim().isNotEmpty &&
        selectedServer != null &&
        selectedServer!.isNotEmpty &&
        _isAudioHandlerServiceReady &&
        _isAnotherRecorderReady;
    if(!_isMicPermissionGranted && kReleaseMode){
      canConnectButtonEnabled = false;
    }

    if (connected) {
      if (_currentGlobalTransmitterId != null) {
        if (_currentGlobalTransmitterId == clientId) {
          channelStatusText = _emisorPttStatus == EmisorLocalPttStatus.transmitting ? "TÚ ESTÁS GRABANDO" : "TÚ ENVIASTE AUDIO";
          channelStatusColorValue = channelStatusOtherRecordingColor;
        } else {
          channelStatusText = "EN CANAL: ${_currentGlobalTransmitterName ?? 'Desconocido'}";
          channelStatusColorValue = channelStatusOtherRecordingColor;
        }
      } else if (_isAudioMessageCurrentlyPlaying && _idOfMessageCurrentlyPlaying != null && _lastReceivedMessageForAutoPlay?.id == _idOfMessageCurrentlyPlaying) {
        channelStatusText = "REPRODUCIENDO DE: ${_lastReceivedMessageForAutoPlay!.senderUsername}";
        channelStatusColorValue = channelStatusPlayingAudioColor;
      } else {
        channelStatusColorValue = channelStatusFreeColor;
      }
    } else {
      channelStatusColorValue = channelStatusFreeColor;
    }

    if (!connected) {
      pttButtonColorValue = pttButtonDisabledColor;
    } else if (!_isMicPermissionGranted && kReleaseMode) {
      pttButtonText = "PERMISO MIC"; pttIcon = Icons.mic_off_rounded;
      pttButtonColorValue = pttButtonDisabledColor;
      pttButtonEnabled = false;
    } else if (!micAndServicesReady) {
      pttButtonText = "AUDIO/REC NO LISTO"; pttIcon = Icons.settings_voice_rounded;
      pttButtonColorValue = pttButtonDisabledColor;
      pttButtonEnabled = false;
    } else {
      if (_isAudioMessageCurrentlyPlaying && _idOfMessageCurrentlyPlaying != null && !_currentPlaybackFinishedOrError) {
        pttButtonText = "REPRODUCIENDO..."; pttIcon = Icons.play_circle_fill_rounded;
        pttButtonColorValue = appAccentColor.withAlpha(200);
        pttButtonEnabled = false;
      } else if (_currentGlobalTransmitterId != null && _currentGlobalTransmitterId != clientId) {
        pttButtonText = "${_currentGlobalTransmitterName ?? 'Alguien'} GRABA"; pttIcon = Icons.hearing_rounded;
        pttButtonColorValue = channelStatusOtherRecordingColor;
        pttButtonEnabled = false;
      } else if (_emisorPttStatus == EmisorLocalPttStatus.requesting) {
        pttButtonText = "SOLICITANDO..."; pttIcon = Icons.timer_outlined;
        pttButtonColorValue = pttButtonRequestingColor;
        pttButtonEnabled = true;
      } else if (_emisorPttStatus == EmisorLocalPttStatus.transmitting) {
        if (_currentRecorderStatus == RecordingStatus.Recording) {
          pttButtonText = "GRABANDO... SUELTA"; pttIcon = Icons.mic_external_on_rounded;
          pttButtonColorValue = pttButtonRecordingColor;
        } else {
          pttButtonText = "INICIANDO GRAB..."; pttIcon = Icons.mic_none_rounded;
          pttButtonColorValue = pttButtonRequestingColor;
        }
        pttButtonEnabled = true;
      } else {
        pttButtonText = "PULSA PARA GRABAR"; pttIcon = Icons.mic_rounded;
        pttButtonColorValue = pttButtonReadyColor;
        pttButtonEnabled = true;
      }
    }

    Color currentPttIconAndTextColor = pttButtonTextColor;

    return Scaffold(
      appBar: AppBar(
        title: SizedBox(
          height: kToolbarHeight - 16,
          child: Image.asset(
            'assets/logo.png',
            fit: BoxFit.contain,
          ),
        ),
        centerTitle: true,
        backgroundColor: appBarDynamicColorValue,
        actions: [
          if (connected)
            IconButton(
              icon: Icon(Icons.logout_rounded),
              tooltip: 'Desconectar',
              onPressed: _disconnect,
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!connected) ...[
              TextField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                      labelText: "Tu Nombre",
                      prefixIcon: Icon(Icons.person_outline)
                  ),
                  onChanged: (val) {
                    if(mounted) setState(() {});
                  },
                  enabled: !connected
              ),
              SizedBox(height: 8),
              Text("Servidor:", style: Theme.of(context).textTheme.bodySmall),
              Row(children: [
                Expanded(child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 10.0),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8.0),
                      border: Border.all(color: Theme.of(context).dividerColor, width: 1),
                      color: Theme.of(context).colorScheme.surface,
                    ),
                    child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: selectedServer,
                          items: servers.isEmpty
                              ? [DropdownMenuItem(value: null, enabled: false, child: Text("Añade un servidor", style: TextStyle(color: Theme.of(context).hintColor.withOpacity(0.6))))]
                              : servers.map((s) => DropdownMenuItem(
                              value: s,
                              child: Row( children: [
                                Flexible(child: Text(s, overflow: TextOverflow.ellipsis)),
                                if (!(servers.length == 1 && selectedServer == s))
                                  IconButton(
                                      icon: Icon(Icons.delete_outline_rounded, size: 20, color: Theme.of(context).iconTheme.color?.withOpacity(0.7)),
                                      onPressed: () => _handleRemoveServer(s),
                                      padding: EdgeInsets.zero,
                                      constraints: BoxConstraints()
                                  )
                              ], ))
                          ).toList(),
                          onChanged: (val) { if (mounted) setState(() { selectedServer = val; }); },
                          isExpanded: true,
                          hint: Text("Selecciona servidor", style: TextStyle(color: Theme.of(context).hintColor.withOpacity(0.6))),
                          borderRadius: BorderRadius.circular(8.0),
                          dropdownColor: Theme.of(context).colorScheme.surface,
                          iconEnabledColor: Theme.of(context).iconTheme.color,
                          style: Theme.of(context).textTheme.bodyMedium,
                        )
                    )
                )),
                IconButton(
                    icon: Icon(Icons.add_circle_outline_rounded, color: Colors.white,),
                    tooltip: "Añadir servidor",
                    onPressed: _handleAddNewServer
                )
              ]),
              SizedBox(height: 12),
              ElevatedButton.icon(
                  icon: Icon(Icons.login_rounded, color: Colors.white,),
                  onPressed: canConnectButtonEnabled ? _connect : null,
                  label: Text("CONECTAR"),
                  style: ElevatedButton.styleFrom(
                    foregroundColor: canConnectButtonEnabled ? textOnPrimaryColor : hintTextColor.withOpacity(0.7),
                    backgroundColor: canConnectButtonEnabled ? appPrimaryColor : appAccentColor.withOpacity(0.3),
                  )
              ),
              if (!micAndServicesReady && mounted)
                Padding(
                    padding: const EdgeInsets.only(top:8.0),
                    child: Text(
                        ((!_isMicPermissionGranted && kReleaseMode) ? "Permiso de Micrófono necesario." : (!_isAudioHandlerServiceReady ? "Sistema de Audio no listo..." : (!_isAnotherRecorderReady ? "Sistema de Grabación (AAR) no listo..." : "Servicios no listos."))),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor.withOpacity(0.7))
                    )
                ),
            ] else ...[
              Text("Conectado como: $username",
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)
              ),
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Text( channelStatusText, textAlign: TextAlign.center, style: TextStyle(color: channelStatusColorValue, fontStyle: FontStyle.italic, fontWeight: FontWeight.bold ) )
              ),
              SizedBox(height: 8),
            ],
            Divider(height: 20, thickness: 1),
            Expanded(
              child: connected
                  ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTapDown: pttButtonEnabled ? (_) => _onPttPress() : null,
                    onTapUp: pttButtonEnabled ? (_) => _onPttRelease() : null,
                    onLongPressStart: pttButtonEnabled ? (_) => _onPttPress() : null,
                    onLongPressEnd: pttButtonEnabled ? (_) => _onPttRelease() : null,
                    onLongPressCancel: pttButtonEnabled ? () => _onPttRelease() : null,
                    child: AnimatedContainer(
                        duration: Duration(milliseconds: 150),
                        padding: EdgeInsets.all(25),
                        constraints: BoxConstraints(minWidth: 140, minHeight: 140, maxWidth: 180, maxHeight: 180),
                        decoration: BoxDecoration(
                          color: pttButtonColorValue,
                          shape: BoxShape.circle,
                          boxShadow: [
                            if(pttButtonEnabled && !( _isAudioMessageCurrentlyPlaying && !_currentPlaybackFinishedOrError ) )
                              BoxShadow(
                                  color: pttButtonColorValue.withOpacity(0.4),
                                  blurRadius: _emisorPttStatus == EmisorLocalPttStatus.transmitting ? 15 : 10,
                                  spreadRadius: _emisorPttStatus == EmisorLocalPttStatus.transmitting ? 5 : 3
                              )
                          ],
                          border: _isAudioMessageCurrentlyPlaying && !_currentPlaybackFinishedOrError
                              ? Border.all(color: generalTextColor.withOpacity(0.7), width: 2)
                              : null,
                        ),
                        child: Column( mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(pttIcon, size: 40, color: currentPttIconAndTextColor),
                            SizedBox(height: 5),
                            Container(
                                width: 90,
                                child: Text(
                                    pttButtonText,
                                    style: TextStyle(color: currentPttIconAndTextColor, fontWeight: FontWeight.bold, fontSize: 11),
                                    textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis
                                )
                            )
                          ],
                        )
                    ),
                  ),
                  if (_lastReceivedMessageForAutoPlay != null && _lastReceivedMessageForAutoPlay!.hasError && _currentPlaybackFinishedOrError)
                    Padding(
                      padding: const EdgeInsets.only(top: 20.0),
                      child: Text(
                          "Error al reproducir el último audio.",
                          style: TextStyle(color: Theme.of(context).colorScheme.error, fontStyle: FontStyle.italic)
                      ),
                    )
                ],
              )
                  : Center(child: Text(
                  !_isMicPermissionGranted && kReleaseMode ? "Permiso de micrófono es necesario." : "Conéctate para usar la función PTT.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).hintColor.withOpacity(0.7))
              )),
            ),
          ],
        ),
      ),
    );
  }
}

