# ppt_app

PTT Flutter web Socket App

La UI es simple y el desarrollo se centro en la funcionalidad de la app

El proyecto utiliza FVM para manejo de version de Flutter revisar el .fvmrc y recuerda que todos los comandos flutter deben usar fvm como cabecera ejemplo: fvm flutter pub get

Dentro del zip ptt_websocket esta el script del server en Python donde se conectara la App,  al crear la app debe tener acceso a la red donde esta el websocket y colocar la configuracion del servidor antes de conectar! 

ejemplo de servidor:  ws://[IP del WebSocket]:8000/ws
