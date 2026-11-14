VED_MESSAGES+=(
    [warn_prefix]="AVISO:"
    [error_prefix]="ERROR:"
    [unknown_option]="Opción desconocida: %s"
    [unexpected_argument]="Argumento inesperado: %s"
    [config_missing]="No se encuentra el archivo de configuración: %s"
    [root_required]="Este script debe ejecutarse con privilegios de administrador."
    [rerun_sudo]="Reiniciando el script mediante sudo..."
    [sudo_password_prompt]="Contraseña de administrador: "
    [sudo_password_incorrect]="Contraseña incorrecta, inténtalo de nuevo."
    [sudo_failed]="No se han podido obtener privilegios de administrador."
    [gui_user_error]="No se ha podido identificar al usuario de la sesión gráfica."
    [execute_from_session]="Ejecute el script desde una sesión gráfica de escritorio normal."
    [runtime_missing]="No existe el directorio de ejecución de la sesión gráfica: %s"
    [runtime_prepare_failed]="No se ha podido crear el directorio de ejecución de la sesión gráfica: %s"
    [guest_uid_mismatch]="El UID del usuario invitado (%s) difiere del UID del host (%s); usar la pantalla del host puede fallar. Pruebe --gui nested."
    [missing_command]="No se encuentra el comando necesario: %s"
    [missing_file]="No se encuentra el archivo necesario: %s"
    [cleanup]="Limpiando archivos temporales..."
    [cleanup_done]="Limpieza terminada."
    [keeping_temp]="Los archivos temporales se han conservado en: %s"
    [backend_invalid]="Backend no válido: %s"
    [guest_os_invalid]="Sistema operativo invitado no válido: %s"
    [storage_invalid]="Modo de almacenamiento no válido: %s"
    [display_invalid]="Modo de pantalla no válido: %s"
    [accel_invalid]="Modo de aceleración no válido: %s"
    [tpm_invalid]="Modo de TPM no válido: %s"
    [unknown_language]="Idioma no soportado: %s"
    [usage]="ved - Dispositivos y sistemas virtuales

Uso:
  ved [opciones]

Ejecuta sin opciones para ver un menú interactivo.

Backends:
  qemu                  Arranca un disco físico, partición o imagen en QEMU/KVM
  chroot                Monta un Linux instalado y entra con chroot
  nspawn                Monta un Linux instalado y lo ejecuta con systemd-nspawn

Opciones comunes:
  -b, --backend NOMBRE  qemu, chroot o nspawn (por defecto: qemu)
  -L, --lang CÓDIGO     Código de idioma: en, es (por defecto: el del entorno)
  -d, --disk DISPOSITIVO
                        Disco físico, por ejemplo /dev/nvme0n1
  -i, --image ARCHIVO   Archivo de imagen de disco (backend qemu)
  -p, --partition DISP  Partición raíz de Linux (backend chroot/nspawn)
      --esp DISPOSITIVO Partición EFI (se detecta automáticamente)
      --os TIPO         auto, linux o windows (por defecto: auto)
      --efi-loader RUTA Cargador EFI relativo a la ESP, o vacío para el menú UEFI
      --storage MODO    temp o persistent (por defecto: preguntar)
      --ram TAMAÑO      Memoria, por ejemplo 8G u 8192M
      --cpus N          Número de CPUs virtuales
      --accel MODO      auto, kvm o tcg (por defecto: auto)
      --tpm             Activa el TPM físico o uno software
      --no-tpm          Desactiva el TPM
      --secure-boot     Usa el firmware OVMF con Secure Boot
      --boot-menu       Muestra el menú de arranque de QEMU (por defecto)
      --no-boot-menu    Oculta el menú de arranque de QEMU
      --network MODO    user o none (por defecto: user)
      --usb VID:PID     Pasa un dispositivo USB a la VM; se puede repetir
      --usb-auto MODO   auto: pasa webcam y Bluetooth, ofrece teléfonos; all:
                        también pasa teléfonos; none: desactiva (por defecto: auto)
      --no-usb          No detecta dispositivos USB automáticamente
      --reset-bluetooth VID:PID
                        Reinicia un dispositivo USB al arrancar la VM
      --display MODO    auto, spice-gl, spice, gtk-gl, gtk, sdl, vnc o none
      --gl              Fuerza la aceleración OpenGL
      --no-gl           Desactiva la aceleración OpenGL
      --render-node DISP
                        Fuerza un nodo de render DRM, por ejemplo /dev/dri/renderD128
      --user NOMBRE     Usuario a usar dentro de chroot o nspawn
  -c, --command ORDEN   Orden a ejecutar en chroot o nspawn
      --graphical       Comparte pantalla y audio del host con chroot/nspawn
      --boot            Arranca el invitado con systemd-nspawn en vez de una orden
      --session MODE    chroot/nspawn: shell, app, desktop o system (por defecto: preguntar)
      --app CMD         Ejecuta una sola aplicación gráfica (implica --session app)
      --gui TARGET      Muestra la sesión gráfica en el host o en una ventana
                        anidada Xephyr: host o nested (por defecto: preguntar)
      --nested          Atajo de --gui nested
      --arch ARCH       Arquitectura del invitado QEMU: auto, x86_64 o aarch64

Otras opciones:
      --config ARCHIVO  Carga un archivo de configuración antes de las opciones
      --no-install      No instala paquetes que falten
  -y, --yes             Responde sí a las confirmaciones
  -n, --dry-run         Muestra la orden de QEMU en vez de ejecutarla
      --keep-temp       Conserva los archivos temporales al salir
  -v, --verbose         Muestra información de depuración
  -h, --help            Muestra esta ayuda
  -V, --version         Muestra la versión"
    [select_backend]="Elija un backend:"
    [select_action]="¿Qué quieres hacer?"
    [select_backend_prompt]="Opción [1]: "
    [backend_qemu]="Arrancarlo como máquina virtual (QEMU/KVM)"
    [backend_chroot]="Entrar en un sistema Linux instalado (chroot)"
    [backend_nspawn]="Ejecutar un sistema Linux instalado como contenedor (systemd-nspawn)"
    [select_session]="¿Qué quieres lanzar dentro del sistema?"
    [session_shell]="Un intérprete de órdenes interactivo"
    [session_app]="Una sola aplicación gráfica"
    [session_desktop]="Una sesión de escritorio completa"
    [session_system]="Arrancar todo el sistema (init/systemd)"
    [select_session_prompt]="Opción [1]: "
    [select_gui_target]="¿Dónde se debe mostrar la sesión gráfica?"
    [gui_target_host]="En el escritorio actual (pantalla del host)"
    [gui_target_nested]="En una ventana anidada aparte (Xephyr)"
    [select_gui_target_prompt]="Opción [1]: "
    [select_arch]="Arquitectura del invitado:"
    [arch_x86_64]="x86_64 / amd64 (PC)"
    [arch_aarch64]="aarch64 / arm64 (ARM, Raspberry Pi)"
    [arch_auto]="Detectar automáticamente"
    [select_arch_prompt]="Opción [1]: "
    [app_command_prompt]="Aplicación a ejecutar, por ejemplo firefox: "
    [app_command_missing]="No se especificó ninguna aplicación para --session app."
    [desktop_session_missing]="No se encontró ninguna sesión de escritorio dentro del sistema."
    [system_needs_nspawn]="Arrancar todo el sistema necesita systemd-nspawn, que no está instalado."
    [system_using_nspawn]="Arrancando todo el sistema mediante systemd-nspawn..."
    [nested_unavailable]="Xephyr no está disponible; se usará la pantalla del host."
    [nested_no_host_display]="No se encontró pantalla del host para la ventana anidada; se usará la pantalla del host."
    [nested_started]="Pantalla anidada iniciada en %s."
    [nested_software_gl]="Xephyr no tiene DRI3; la sesión anidada usará renderizado por software."
    [nested_failed]="No se pudo iniciar la pantalla anidada; se usará la pantalla del host."
    [platform_unknown]="Distribución no soportada: %s"
    [pkg_manager_unknown]="No se ha encontrado un gestor de paquetes soportado."
    [installing_dependencies]="Instalando paquetes: %s"
    [dependencies_ready]="Las dependencias están disponibles."
    [install_failed]="Falló la instalación de paquetes: %s"
    [missing_packages]="Faltan paquetes y se pidió --no-install: %s"
    [kvm_missing]="No hay virtualización por hardware; se usará TCG (lento)."
    [kvm_enabled]="La aceleración KVM está activada."
    [no_disks]="No se han encontrado discos físicos."
    [available_disks]="Discos disponibles:"
    [select_disk]="¿Qué disco desea utilizar? [1]: "
    [invalid_selection]="Selección no válida."
    [selected_disk]="Disco seleccionado:"
    [disk_missing]="No existe el disco seleccionado: %s"
    [no_partitions]="No se han encontrado particiones Linux utilizables en: %s"
    [available_partitions]="Particiones raíz de Linux disponibles:"
    [select_partition]="¿Qué partición raíz desea utilizar? [1]: "
    [selected_partition]="Partición seleccionada:"
    [partition_missing]="No existe la partición seleccionada: %s"
    [mounted_disk]="Hay una o más particiones de este disco montadas:"
    [no_efi]="No se ha encontrado ninguna partición EFI en: %s"
    [detected_efi]="Partición EFI detectada:"
    [efi_missing]="No existe la partición EFI seleccionada: %s"
    [mounting_source]="Montando la partición EFI original en modo solo lectura..."
    [luks_partition]="La partición %s es una partición LUKS cifrada. Desbloquéela primero (cryptsetup luksOpen) y use el dispositivo mapeado."
    [lvm_partition]="La partición %s es un volumen físico LVM. Active el grupo de volúmenes (vgchange -ay) y use el dispositivo lógico."
    [efi_loaders]="Cargadores EFI detectados:"
    [no_loaders]="No se han encontrado cargadores EFI en: %s"
    [uefi_menu]="Mostrar el menú UEFI de QEMU"
    [select_loader]="¿Qué cargador desea utilizar? [1]: "
    [selected_loader]="Cargador EFI seleccionado:"
    [loader_missing]="No existe el cargador seleccionado: %s"
    [invalid_efi_loader]="Ruta de cargador EFI no válida: %s"
    [system_memory]="Memoria del equipo:"
    [total_memory]="Memoria total: %s MiB"
    [available_memory]="Memoria disponible aproximadamente: %s MiB"
    [recommended_memory]="Memoria recomendada para la VM: %sG"
    [select_memory]="¿Cuánta memoria desea asignar? [%sG]: "
    [invalid_memory]="Formato no válido. Utilice, por ejemplo: 8G, 16G u 8192M."
    [processors]="Procesadores:"
    [total_processors]="Totales: %s"
    [available_processors]="Disponibles ahora: %s"
    [recommended_processors]="CPUs recomendadas para la VM: %s"
    [select_cpus]="¿Cuántas CPUs desea asignar? [%s]: "
    [invalid_cpus]="Número no válido. Introduzca un valor entre 1 y %s."
    [configuration]="Configuración seleccionada:"
    [backend_label]="Backend: %s"
    [disk_label]="Disco: %s"
    [image_label]="Imagen: %s"
    [partition_label]="Partición: %s"
    [efi_label]="EFI: %s"
    [ram_label]="RAM: %s"
    [cpu_label]="CPUs: %s"
    [storage_label]="Almacenamiento: %s"
    [display_label]="Pantalla: %s"
    [accel_label]="Aceleración: %s"
    [gl_label]="OpenGL: %s"
    [render_label]="Nodo de render: %s"
    [network_label]="Red: %s"
    [guest_label]="Invitado: %s"
    [secure_boot_label]="Secure Boot: %s"
    [graphical_label]="Sesión gráfica: %s"
    [session_label]="Lanzar: %s"
    [gui_label]="Pantalla: %s"
    [arch_label]="Arquitectura: %s"
    [value_enabled]="activado"
    [value_disabled]="desactivado"
    [value_kvm]="KVM (hardware)"
    [value_tcg]="TCG (software, lento)"
    [yes_value]="sí"
    [tmp_label]="Archivos temporales: %s"
    [image_missing]="No existe la imagen de disco: %s"
    [image_format_unknown]="Formato de imagen desconocido: %s"
    [image_and_disk]="Use --image o --disk, pero no ambos."
    [network_invalid]="Modo de red no válido: %s"
    [storage_mode]="Modo de almacenamiento:"
    [temporary_storage]="Temporal: descartar los cambios al salir"
    [persistent_storage]="Persistente: guardar los cambios en el disco"
    [select_storage]="Opción [1]: "
    [temporary_selected]="Modo temporal seleccionado."
    [persistent_selected]="Modo persistente seleccionado."
    [persistent_warning]="ADVERTENCIA: los cambios se escribirán directamente en el disco físico."
    [confirm_persistent]="¿Desea continuar? [s/N]: "
    [confirm_yes]="¿Desea continuar? [S/n]: "
    [invalid_option]="Opción no válida."
    [session_invalid]="Modo de sesión no válido: %s"
    [gui_target_invalid]="Destino de pantalla no válido: %s"
    [arch_invalid]="Arquitectura no válida: %s"
    [aborted]="Cancelado."
    [creating_esp]="Creando la partición EFI virtual temporal..."
    [copying_efi]="Copiando archivos EFI..."
    [creating_vars]="Creando la NVRAM UEFI temporal..."
    [creating_tpm]="Iniciando el TPM software..."
    [tpm_passthrough]="Usando el TPM físico en modo passthrough."
    [tpm_swtpm]="Usando un emulador de TPM software."
    [tpm_disabled]="TPM desactivado."
    [tpm_missing]="No se ha encontrado un TPM físico ni swtpm; TPM desactivado."
    [tpm_in_use]="El TPM software ya está siendo usado por otra VM."
    [secure_boot_enabled]="Firmware con Secure Boot seleccionado."
    [arch_detected]="Arquitectura del invitado detectada: %s"
    [cross_arch_tcg]="Emulando %s con TCG (lento)."
    [aarch64_qemu_missing]="No se encontró qemu-system-aarch64; instálalo para ejecutar imágenes ARM."
    [aavmf_missing]="No se encontró el firmware UEFI ARM (AAVMF/edk2-aarch64); instálalo para arrancar imágenes ARM."
    [aavmf_secure_missing]="Secure Boot para ARM necesita firmware AAVMF seguro de código y variables; instala el paquete seguro AAVMF/edk2-aarch64."
    [no_render_node]="No se ha encontrado ningún nodo de render DRM; OpenGL desactivado."
    [render_node]="Nodo de render OpenGL: %s"
    [gl_disabled]="Aceleración OpenGL desactivada."
    [starting_qemu]="Arrancando QEMU..."
    [qemu_command]="Orden de QEMU:"
    [waiting_spice]="Esperando al servidor SPICE..."
    [spice_ready]="QEMU está escuchando en el socket SPICE."
    [spice_error]="No se ha podido crear el socket SPICE: %s"
    [qemu_failed]="No se ha podido arrancar QEMU."
    [qemu_log]="Registro de QEMU: %s"
    [qemu_stopped]="QEMU se ha detenido."
    [qemu_running]="QEMU está en ejecución. Cierra la ventana o pulsa Ctrl+C para detenerlo."
    [headless_running]="QEMU se está ejecutando sin pantalla. Pulsa Ctrl+C para detenerlo."
    [no_display]="No se ha encontrado un modo de pantalla utilizable. Prueba --display none o instala un visor."
    [trying_display]="Probando el modo de pantalla: %s"
    [display_fallback]="El modo de pantalla falló; probando la siguiente opción."
    [display_active]="Modo de pantalla activo: %s"
    [gl_active]="Aceleración OpenGL activa en: %s"
    [connecting_viewer]="Conectando con el visor gráfico..."
    [graphical_user]="Usuario gráfico: %s"
    [resize_hint]="Puede redimensionar la ventana."
    [no_viewer]="No se ha encontrado ningún visor SPICE. Conéctese manualmente a: %s"
    [viewer_failed]="El visor se cerró; la VM sigue en marcha. Pulse Ctrl+C para detenerla."
    [vnc_listening]="VNC está escuchando en 127.0.0.1:5900."
    [guest_os_linux]="Invitado Linux detectado."
    [guest_os_windows]="Invitado Windows detectado."
    [guest_os_unknown]="No se ha podido detectar el sistema invitado; se asume Linux."
    [guest_os_forced]="Sistema invitado forzado a: %s"
    [usb_passthrough]="Pasando el dispositivo USB a la VM: %s"
    [usb_not_found]="No se ha encontrado el dispositivo USB; se omite: %s"
    [usb_invalid]="Identificador USB no válido (se espera VID:PID): %s"
    [usb_auto_webcam]="Webcam detectada automáticamente: %s"
    [usb_auto_bluetooth]="Adaptador Bluetooth detectado automáticamente: %s"
    [usb_auto_android]="Pasando dispositivo Android: %s"
    [usb_offer_android]="¿Pasar el dispositivo Android \"%s\" a la VM? [S/n]: "
    [usb_skipped]="Dispositivo USB omitido: %s"
    [usb_auto_disabled]="Detección automática de USB desactivada."
    [usb_auto_invalid]="Modo de detección USB no válido: %s"
    [usb_label]="USB: %s"
    [bluetooth_reset]="Reiniciando el dispositivo USB: %s"
    [bluetooth_not_found]="No se ha encontrado el dispositivo USB que se quería reiniciar: %s"
    [bluetooth_reset_done]="Reinicio del dispositivo USB completado: %s"
    [audio_enabled]="Audio activado con el controlador: %s"
    [audio_disabled]="Audio desactivado."
    [chroot_mounting]="Montando la partición raíz de Linux..."
    [chroot_ready]="La raíz de Linux está lista en: %s"
    [chroot_entering]="Entrando en chroot como usuario: %s"
    [chroot_command]="Ejecutando una orden en chroot: %s"
    [chroot_shell]="Abriendo un intérprete de órdenes en el chroot."
    [chroot_graphical]="Compartiendo la pantalla y el audio del host en un directorio de ejecución privado."
    [chroot_security_warning]="chroot no es una frontera de seguridad; úselo solo con un sistema instalado de confianza."
    [chroot_no_user]="No se ha encontrado un usuario utilizable dentro del chroot; se usará root."
    [chroot_unmount]="Desmontando los sistemas de archivos del chroot..."
    [chroot_bind_failed]="No se pudo montar por bind: %s"
    [nspawn_missing]="systemd-nspawn no está instalado; instale systemd-container o systemd."
    [nspawn_starting]="Arrancando systemd-nspawn..."
    [nspawn_boot]="Arrancando el contenedor con systemd-nspawn..."
    [nspawn_shell]="Abriendo un intérprete de órdenes en el contenedor."
    [nspawn_command]="Ejecutando una orden en el contenedor: %s"
    [nspawn_graphical]="Compartiendo la pantalla, el audio y la GPU del host en un directorio de ejecución privado."
    [nspawn_requires_systemd]="La raíz seleccionada no parece una instalación con systemd."
    [confirm_run]="¿Arrancar ahora? [S/n]: "
    [no_tty]="Esta operación necesita una terminal interactiva o que se indiquen las opciones necesarias."
    [dry_run]="Simulación: se ejecutaría la siguiente orden:"
    [auto_value]="auto"
    [press_enter]="Pulse Intro para continuar..."
    [nspawn_stopping]="Deteniendo el contenedor: %s"
    [nspawn_rebooting]="Reiniciando el contenedor: %s"
    [nspawn_powering_off]="Apagando el contenedor: %s"
    [nspawn_status_hint]=" Ctrl+A luego: [S]Detener  [R]Reiniciar  [P]Apagar  [Q]Salir ved "
    [nspawn_status_hint_cmd]=" Modo comando: [S]Detener  [R]Reiniciar  [P]Apagar  [Q]Salir  [Esc] cancelar "
    [nspawn_status_machine]=" Máquina: %s  PID: %s "
)
