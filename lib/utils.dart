// lib/utils.dart
import 'package:flutter/foundation.dart'; // Para kDebugMode (opcional si quieres logs desde utils)

// Ejemplo: Función para construir la URL de descarga de audio
// Esta función es pura y no depende del estado del widget.
String? buildAudioDownloadUrl({
  required String? selectedServerUrl, // ej. ws://192.168.1.10:8000/ws
  required String? messageId,
  required String? filenameFromServer,
}) {
  if (selectedServerUrl == null || messageId == null || filenameFromServer == null) {
    if (kDebugMode) {
      print("UTILS_WARN: No se puede construir URL de descarga, datos incompletos. Server: $selectedServerUrl, MsgID: $messageId, Filename: $filenameFromServer");
    }
    return null;
  }

  String? baseUrlForDownload;
  if (selectedServerUrl.startsWith("ws://")) {
    baseUrlForDownload = selectedServerUrl.replaceFirst("ws://", "http://");
  } else if (selectedServerUrl.startsWith("wss://")) {
    baseUrlForDownload = selectedServerUrl.replaceFirst("wss://", "https://");
  }

  if (baseUrlForDownload != null && baseUrlForDownload.endsWith("/ws")) {
    baseUrlForDownload = baseUrlForDownload.substring(0, baseUrlForDownload.length - 3);
  }

  if (baseUrlForDownload == null) {
    if (kDebugMode) {
      print("UTILS_WARN: No se pudo derivar baseUrlForDownload desde $selectedServerUrl");
    }
    return null;
  }

  return "$baseUrlForDownload/audio/$messageId/$filenameFromServer";
}

// Ejemplo: Función para generar un nombre de archivo local único para descargas
// Incluye el messageId para evitar colisiones y la extensión original.
String generateLocalFilenameForDownload({
  required String messageId,
  required String originalFilename, // ej. "simulated_audio.ogg"
  required String tempFilenameBase, // ej. "ptt_rcv_playback"
}) {
  String extension = ".dat"; // Default por si no hay extensión
  if (originalFilename.contains(".")) {
    extension = originalFilename.substring(originalFilename.lastIndexOf("."));
  }
  // Asegurarse de que la base no tenga ya una extensión que cause duplicados
  String cleanBase = tempFilenameBase;
  if (tempFilenameBase.contains(".")) {
    cleanBase = tempFilenameBase.substring(0, tempFilenameBase.lastIndexOf("."));
  }

  return "${messageId}_$cleanBase$extension";
}

// Podríamos añadir más funciones aquí después, como formateadores de logs, etc.

