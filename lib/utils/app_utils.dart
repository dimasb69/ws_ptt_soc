import 'package:flutter/material.dart';
import 'dart:math'; // Para Random
import '../config/app_theme.dart';

void showAppMessage(BuildContext context, String msg, {bool isError = false, int? durationSeconds}) {
  ScaffoldMessenger.of(context).removeCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        msg,
        style: TextStyle(
          color: isError
              ? Theme.of(context).colorScheme.onError
              : Theme.of(context).colorScheme.onSecondary,
        ),
      ),
      duration: Duration(seconds: durationSeconds ?? (isError ? 4 : 2)),
      backgroundColor: isError
          ? Theme.of(context).colorScheme.error
          : Theme.of(context).colorScheme.secondary,
      behavior: SnackBarBehavior.floating,
    ),
  );
}

// Para _addServer y _removeServer, necesitamos una forma de actualizar el estado
// en el widget que llama. Usaremos callbacks para esto.

void showAddServerDialog({
  required BuildContext context,
  required Function(String newUrl) onServerAdded,
  required Function(String message, {bool isError}) showMessageCallback, // Para mostrar mensajes desde el diálogo
}) {
  final controller = TextEditingController();
  showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        // Usamos el tema del dialogContext para asegurar consistencia
        final dialogTheme = Theme.of(dialogContext);
        return AlertDialog(
          backgroundColor: dialogTheme.colorScheme.surface,
          title: Text("Agregar Servidor", style: dialogTheme.textTheme.titleLarge),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: "ws://ip:puerto/ws",
              // Aplicamos estilos del tema del diálogo
              border: dialogTheme.inputDecorationTheme.border,
              focusedBorder: dialogTheme.inputDecorationTheme.focusedBorder,
              labelStyle: dialogTheme.inputDecorationTheme.labelStyle,
              hintStyle: dialogTheme.inputDecorationTheme.hintStyle,
            ),
            keyboardType: TextInputType.url,
            style: dialogTheme.textTheme.bodyMedium,
          ),
          actions: [
            TextButton(
                style: dialogTheme.textButtonTheme.style,
                onPressed: () {
                  final url = controller.text.trim();
                  if (url.isNotEmpty && (url.startsWith("ws://") || url.startsWith("wss://"))) {
                    onServerAdded(url); // El widget se encargará de la lógica de duplicados y setState
                  } else {
                    showMessageCallback("URL inválida.", isError: true);
                  }
                  Navigator.pop(dialogContext);
                },
                child: Text("Agregar")
            ),
            TextButton(
                style: dialogTheme.textButtonTheme.style,
                onPressed: () => Navigator.pop(dialogContext),
                child: Text("Cancelar")
            ),
          ],
        );
      }
  );
}

Map<String, dynamic> prepareServerRemoval({
  required List<String> currentServers,
  required String? currentSelectedServer,
  required String urlToRemove,
  required Function(String message, {bool isError}) showMessageCallback,
}) {
  if (currentServers.length <= 1 && currentServers.contains(urlToRemove)) {
    showMessageCallback("No puedes eliminar el único servidor.", isError: true);
    return {
      'servers': currentServers,
      'selectedServer': currentSelectedServer,
      'removed': false,
    };
  }

  List<String> updatedServers = List.from(currentServers);
  String? newSelectedServer = currentSelectedServer;

  bool removed = updatedServers.remove(urlToRemove);

  if (removed) {
    if (newSelectedServer == urlToRemove) {
      newSelectedServer = updatedServers.isNotEmpty ? updatedServers.first : null;
    }
    showMessageCallback("Servidor '$urlToRemove' eliminado.", isError: false);
    return {
      'servers': updatedServers,
      'selectedServer': newSelectedServer,
      'removed': true,
    };
  }

  return {
    'servers': currentServers,
    'selectedServer': currentSelectedServer,
    'removed': false,
  };
}


String? buildAudioDownloadUrl({
  required String? selectedServerUrl,
  required String? messageId,
  required String? filenameFromServer,
}) {
  if (selectedServerUrl == null || messageId == null || filenameFromServer == null) {
    return null;
  }

  String httpBaseUrl = selectedServerUrl.replaceFirst(RegExp(r'^ws'), 'http');
  if (httpBaseUrl.endsWith("/ws")) {
    httpBaseUrl = httpBaseUrl.substring(0, httpBaseUrl.length - 3);
  }


  if (httpBaseUrl.endsWith('/')) {
    httpBaseUrl = httpBaseUrl.substring(0, httpBaseUrl.length - 1);
  }


  return '$httpBaseUrl/audio/$messageId/$filenameFromServer';
}

String generateLocalFilenameForDownload({
  required String messageId,
  required String originalFilename,
  required String tempFilenameBase,
}) {
  final String fileExtension = originalFilename.contains('.')
      ? originalFilename.substring(originalFilename.lastIndexOf('.'))
      : '.m4a';

  final safeMessageId = messageId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
  return '${tempFilenameBase}_${safeMessageId}_${Random().nextInt(99999)}$fileExtension';
}

