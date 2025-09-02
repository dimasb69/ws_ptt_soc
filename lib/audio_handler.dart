// lib/audio_handler.dart
import 'package:just_audio/just_audio.dart';
import 'package:flutter/foundation.dart'; // Para kDebugMode (opcional para logs)

class AudioHandlerService {
  AudioPlayer? _beepPlayer;
  AudioPlayer? _messagePlayer; // Player dedicado para los mensajes de voz

  String? _clientIdForLogs; // Para logs, si lo necesitas
  String? _currentlyPlayingMessageId; // ID del mensaje que se está reproduciendo
  bool _isMessagePlayerInitialized = false;

  AudioHandlerService() {
    _beepPlayer = AudioPlayer();
    _messagePlayer = AudioPlayer();
    _isMessagePlayerInitialized = true; // Asumimos que se inicializa bien
  }

  void setClientIdForLogs(String clientId) {
    _clientIdForLogs = clientId;
  }

  Future<void> initAudio() async {
    // Podrías precargar los beeps aquí si quieres, aunque setAsset los carga al usar.
    _log("AudioHandlerService inicializado.");
  }

  void _log(String message) {
    if (kDebugMode && _clientIdForLogs != null) {
      print("$_clientIdForLogs AUDIO_SVC: $message");
    } else if (kDebugMode) {
      print("AUDIO_SVC: $message");
    }
  }

  Future<void> playBeep(String assetPath, String beepIdentifier) async {
    if (_beepPlayer == null) {
      _log("ERR: BeepPlayer no inicializado al intentar reproducir $beepIdentifier");
      return;
    }
    try {
      _log("Reproduciendo beep: $beepIdentifier desde $assetPath");
      await _beepPlayer!.setAsset(assetPath);
      await _beepPlayer!.play();
    } catch (e) {
      _log("ERR: Reproduciendo beep $beepIdentifier: $e");
    }
  }

  Future<void> cancelCurrentBeep() async {
    if (_beepPlayer != null && _beepPlayer!.playing) {
      _log("Cancelando beep actual.");
      await _beepPlayer!.stop();
    }
  }

  Future<void> playAudioFile(
      String filePath,
      String messageId, {
        VoidCallback? onStarted,
        VoidCallback? onCompleted,
        Function(Object)? onError,
      }) async {
    if (!_isMessagePlayerInitialized || _messagePlayer == null) {
      _log("ERR: MessagePlayer no inicializado al intentar reproducir $messageId");
      onError?.call(Exception("MessagePlayer no inicializado"));
      return;
    }

    // Detener reproducción anterior si la hay o si es un mensaje diferente
    if (_messagePlayer!.playing) {
      _log("Mensaje ya sonando ($_currentlyPlayingMessageId), deteniendo para reproducir $messageId.");
      await stopCurrentMessagePlayback(); // Detener el anterior
    }

    _currentlyPlayingMessageId = messageId;
    _log("Reproduciendo archivo: $filePath (ID: $messageId)");

    try {
      // Configurar listener ANTES de setFilePath o play
      _messagePlayer!.playerStateStream.firstWhere((state) => state.processingState == ProcessingState.completed).then((_) {
        if (_currentlyPlayingMessageId == messageId) { // Asegurar que es el mismo mensaje
          _log("PlayerStateStream - Reproducción completada para $messageId");
          onCompleted?.call();
          _currentlyPlayingMessageId = null;
        }
      }).catchError((e) { // En caso de que el stream se cierre con error antes de completar
        if (_currentlyPlayingMessageId == messageId) {
          _log("PlayerStateStream ERR - Error durante la reproducción de $messageId: $e");
          onError?.call(e);
          _currentlyPlayingMessageId = null;
        }
      });

      await _messagePlayer!.setFilePath(filePath);
      onStarted?.call();
      await _messagePlayer!.play();

    } catch (e) {
      _log("ERR: Reproduciendo $filePath: $e");
      onError?.call(e);
      _currentlyPlayingMessageId = null;
    }
  }

  Future<void> stopCurrentMessagePlayback() async {
    if (_messagePlayer != null && _messagePlayer!.playing) {
      _log("Deteniendo reproducción de mensaje actual: $_currentlyPlayingMessageId");
      await _messagePlayer!.stop();
      // El callback onCompleted del listener de playerStateStream debería activarse si el stop lleva a completed.
      // Si no, necesitamos manejar el estado _currentlyPlayingMessageId aquí también.
      // Por seguridad, lo limpiamos.
      _currentlyPlayingMessageId = null;
    } else {
      _log("No hay mensaje reproduciéndose para detener.");
    }
  }

  void dispose() {
    _log("Liberando players.");
    _beepPlayer?.dispose();
    _beepPlayer = null;
    _messagePlayer?.dispose();
    _messagePlayer = null;
    _isMessagePlayerInitialized = false;
    _currentlyPlayingMessageId = null;
  }
}
