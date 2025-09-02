import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';

class AudioHandlerService {
  bool _isMountedCheck = true;

  final AudioPlayer _audioPlayer = AudioPlayer();
  Completer<void>? _playbackCompleter;
  StreamSubscription? _playerStateSubscription;
  String? _currentPlayingMessageId;
  String? _currentBeepIdentifier;

  String get _logTag => "[AudioSvc]";

  bool _logIfNeeded(String message, {bool isError = false}) {
    if (_isMountedCheck) {
      if (kDebugMode || isError) {
        print("$_logTag $message");
      }
      return true;
    }
    return false;
  }

  Future<void> initAudio() async {
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.defaultToSpeaker | AVAudioSessionCategoryOptions.allowBluetooth,
      avAudioSessionMode: AVAudioSessionMode.voiceChat,
      avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
      avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        flags: AndroidAudioFlags.none,
        usage: AndroidAudioUsage.voiceCommunication,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: true,
    ));
    _logIfNeeded("AudioSession configurada.");
  }

  Future<void> _stopPlayerAndCleanUp() async {
    if (_audioPlayer.playing || _audioPlayer.processingState != ProcessingState.idle) {
      await _audioPlayer.stop();
    }
    await _playerStateSubscription?.cancel();
    _playerStateSubscription = null;
    if (_playbackCompleter != null && !_playbackCompleter!.isCompleted) {
      _playbackCompleter!.completeError(Exception("Playback stopped or superseded by new action"));
    }
    _playbackCompleter = null;
    _currentPlayingMessageId = null;
  }

  Future<void> playBeep(String assetPath, String beepId) async {
    if (!_logIfNeeded("Solicitado beep '$beepId'")) return;

    await _stopPlayerAndCleanUp();

    _currentBeepIdentifier = beepId;
    _currentPlayingMessageId = null;

    try {
      _logIfNeeded("Cargando beep $beepId...");
      await _audioPlayer.setAsset(assetPath);
      _logIfNeeded("Beep $beepId cargado. Reproduciendo...");
      _audioPlayer.play();

      StreamSubscription? beepCompletionSubscription;
      beepCompletionSubscription = _audioPlayer.playerStateStream.listen((state) {
        if (_currentBeepIdentifier != beepId) {
          beepCompletionSubscription?.cancel();
          return;
        }
        if (state.processingState == ProcessingState.completed) {
          _logIfNeeded("Beep $beepId reproducción completada.");
          if (_currentBeepIdentifier == beepId) _currentBeepIdentifier = null;
          beepCompletionSubscription?.cancel();
        }
      }, onError: (e) {
        _logIfNeeded("Error en stream de beep $beepId: $e", isError: true);
        if (_currentBeepIdentifier == beepId) _currentBeepIdentifier = null;
        beepCompletionSubscription?.cancel();
      });

    } catch (e) {
      _logIfNeeded("Excepción al reproducir beep $beepId: $e", isError: true);
      if (_currentBeepIdentifier == beepId) _currentBeepIdentifier = null;
    }
  }

  Future<void> cancelCurrentBeep() async {
    if (_currentBeepIdentifier != null) {
      _logIfNeeded("Cancelando beep actual: $_currentBeepIdentifier");
      await _audioPlayer.stop();
      _currentBeepIdentifier = null;
    }
  }

  Future<void> stopCurrentMessagePlayback() async {
    _logIfNeeded("stopCurrentMessagePlayback llamado...");
    await _stopPlayerAndCleanUp();
  }

  Future<void> playAudioFile(
      String filePath,
      String messageId,
      {required VoidCallback onStarted,
        required VoidCallback onCompleted,
        required Function(dynamic) onError}
      ) async {
    if (!_logIfNeeded("playAudioFile: Solicitado $messageId desde $filePath")) {
      return Future.error(Exception("Servicio no montado o log prevenido al inicio de playAudioFile"));
    }

    await _stopPlayerAndCleanUp();

    _playbackCompleter = Completer<void>();
    _currentPlayingMessageId = messageId;
    _currentBeepIdentifier = null;

    try {
      _logIfNeeded("playAudioFile: Estableciendo fuente $messageId");
      await _audioPlayer.setFilePath(filePath);

      onStarted();

      _playerStateSubscription = _audioPlayer.playerStateStream.listen(
              (state) {
            if (_currentPlayingMessageId != messageId || _playbackCompleter == null || _playbackCompleter!.isCompleted) {
              return;
            }

            if (state.processingState == ProcessingState.completed) {
              _logIfNeeded("playAudioFile: Reproducción completada para $messageId");
              onCompleted();
              if (!_playbackCompleter!.isCompleted) {
                _playbackCompleter!.complete();
              }
            }
          },
          onError: (e) {
            if (_currentPlayingMessageId != messageId || _playbackCompleter == null || _playbackCompleter!.isCompleted) {
              return;
            }
            _logIfNeeded("playAudioFile: Error en stream para $messageId: $e", isError: true);
            onError(e);
            if (!_playbackCompleter!.isCompleted) {
              _playbackCompleter!.completeError(e);
            }
          }
      );

      _logIfNeeded("playAudioFile: Iniciando reproducción de $messageId...");
      await _audioPlayer.play();

    } catch (e, s) {
      _logIfNeeded("playAudioFile: Excepción al reproducir $messageId: $e\nStackTrace: $s", isError: true);
      onError(e);
      if (_playbackCompleter != null && !_playbackCompleter!.isCompleted) {
        _playbackCompleter!.completeError(e);
      }
    }

    if (_playbackCompleter == null) {
      _logIfNeeded("playAudioFile: Fallback - Completer nulo para $messageId", isError: true);
      return Future.error(Exception("Completer no inicializado para $messageId"));
    }
    return _playbackCompleter!.future;
  }

  void dispose() {
    _isMountedCheck = false;
    _logIfNeeded("AudioHandlerService dispose.");

    _playerStateSubscription?.cancel();
    _audioPlayer.dispose();
    if (_playbackCompleter != null && !_playbackCompleter!.isCompleted) {
      _playbackCompleter!.completeError(Exception("Service disposed"));
    }
    _playbackCompleter = null;
    _currentPlayingMessageId = null;
    _currentBeepIdentifier = null;
  }
}
