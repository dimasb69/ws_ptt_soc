import 'package:flutter/material.dart';

// --- Paleta Principal (Basada en tu "Dark" original, será el único tema) ---
const Color appScaffoldBg = Color(0xFF8F8C8C);      // Fondo principal oscuro
const Color appSurfaceColor = Color(0xFF857A7A);    // Superficies oscuras
const Color appPrimaryColor = Color(0xFF4D5B4D);    // Primario (botones, etc.)
const Color appAccentColor = Color(0xFF7E7C83);     // Acento

// --- Colores Específicos ---
const Color appBarBackgroundColor = Color(0xFFD0C4C4); // AppBar GRIS CLARO FIJO
const Color appBarTextColor = Colors.black;             // Texto e iconos del AppBar NEGROS
const Color generalTextColor = Color(0xFF2F2D2D);      // Texto general CLARO (para fondos oscuros) (era clrDarkTextOnScaffold)
const Color textOnPrimaryColor = Color(0xFFC2BEBE);    // Texto sobre botones primarios (oscuro sobre primario claro-ish)
const Color textOnAccentColor = Color(0xFFD5D0D0);     // Texto sobre botones de acento (claro sobre acento oscuro-ish)
const Color hintTextColor = Color(0xFFEFD7D7);        // Hint CLARO (era clrDarkHintText, o un gris más claro)

// Colores para el Botón PTT (Mantenemos la lógica de tu tema oscuro original para estos)
const Color pttButtonReadyColor = Color(0xFF555B4D);
const Color pttButtonRequestingColor = Color(0xFFB6F1C6);
const Color pttButtonRecordingColor = Color(0xFF969191);
const Color pttButtonDisabledColor = Color(0x667E7E7E);
const Color pttButtonTextColor = Color(0xFFCBC8D0); // Texto del botón PTT (oscuro sobre fondos PTT más claros)

// Colores de Estado del Canal (Adaptados de tu tema oscuro original)
const Color channelStatusOtherRecordingColor = Color(0xFFA44C4C);
const Color channelStatusPlayingAudioColor = Color(0xFF3E6D96);
const Color channelStatusFreeColor = Color(0xFF99CC83); // Para "CANAL LIBRE" (mismo que hintTextColor)


// Colores de Error (Mantenemos los del tema oscuro original)
const Color errorColor = Color(0xFFAB263C);
const Color onErrorColor = Colors.black; // Texto sobre el color de error

ThemeData getAppTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark, // El tema base es oscuro
    primaryColor: appPrimaryColor,
    scaffoldBackgroundColor: appScaffoldBg,
    appBarTheme: AppBarTheme(
      backgroundColor: appBarBackgroundColor, // Gris claro
      elevation: 1,
      titleTextStyle: TextStyle(color: appBarTextColor, fontSize: 20, fontWeight: FontWeight.w500), // Texto negro
      iconTheme: IconThemeData(color: appBarTextColor), // Iconos negros
    ),
    colorScheme: ColorScheme(
      brightness: Brightness.dark,
      primary: appPrimaryColor,
      onPrimary: textOnPrimaryColor,
      secondary: appAccentColor,
      onSecondary: textOnAccentColor,
      error: errorColor,
      onError: onErrorColor,
      surface: appSurfaceColor,
      onSurface: generalTextColor, // Texto claro sobre superficies oscuras
      background: appScaffoldBg,
      onBackground: generalTextColor, // Texto claro sobre fondo oscuro
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: textOnPrimaryColor,
        backgroundColor: appPrimaryColor,
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 20),
        textStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: BorderSide(color: appAccentColor.withOpacity(0.7)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: BorderSide(color: appPrimaryColor, width: 2.0),
      ),
      labelStyle: TextStyle(color: hintTextColor),
      hintStyle: TextStyle(color: hintTextColor.withOpacity(0.8)),
      prefixIconColor: hintTextColor,
      suffixIconColor: hintTextColor,
      filled: true, // Para que el fillColor se aplique
      fillColor: appSurfaceColor.withOpacity(0.5), // Un poco de color de fondo para los inputs
    ),
    textTheme: TextTheme( // Todo el texto por defecto será generalTextColor (claro)
      bodyLarge: TextStyle(color: generalTextColor),
      bodyMedium: TextStyle(color: generalTextColor), // Ajustado, antes era hintTextColor
      titleLarge: TextStyle(color: generalTextColor, fontWeight: FontWeight.w500), // Títulos grandes
      titleMedium: TextStyle(color: generalTextColor, fontWeight: FontWeight.w500),
      titleSmall: TextStyle(color: generalTextColor),
      labelLarge: TextStyle(color: generalTextColor), // Para TextButton si no se anula
      labelMedium: TextStyle(color: hintTextColor), // Textos de etiquetas más pequeños/hints
      labelSmall: TextStyle(color: hintTextColor),
      bodySmall: TextStyle(color: hintTextColor), // Textos pequeños como "Servidor:"
      displayLarge: TextStyle(color: generalTextColor),
      displayMedium: TextStyle(color: generalTextColor),
      displaySmall: TextStyle(color: generalTextColor),
      headlineLarge: TextStyle(color: generalTextColor),
      headlineMedium: TextStyle(color: generalTextColor),
      headlineSmall: TextStyle(color: generalTextColor),
    ),
    iconTheme: IconThemeData(color: appPrimaryColor), // Iconos generales (que no estén en AppBar)
    dividerColor: appAccentColor.withOpacity(0.5),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: appPrimaryColor),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: TextStyle(color: generalTextColor),
        inputDecorationTheme: InputDecorationTheme(
          labelStyle: TextStyle(color: hintTextColor),
          hintStyle: TextStyle(color: hintTextColor.withOpacity(0.8)),
          filled: true,
          fillColor: appSurfaceColor, // Fondo del dropdown
          border: UnderlineInputBorder(borderSide: BorderSide(color: appAccentColor.withOpacity(0.7))),
          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: appPrimaryColor)),
        )
    ),
    dialogTheme: DialogTheme(
      backgroundColor: appSurfaceColor,
      titleTextStyle: TextStyle(color: generalTextColor, fontSize: 20, fontWeight: FontWeight.bold),
      contentTextStyle: TextStyle(color: generalTextColor),
    ),
  );
}

// Las constantes exportadas para el botón PTT y estado del canal no cambian,
// ya que se basan en tu configuración original del tema oscuro y son fijas.
// const Color pttButtonReadyColor = ...; // ya definidas arriba
// etc.

