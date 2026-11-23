chroot_bind() {
    local source="$1"
    local target="$2"
    local recursion="${3:-rbind}"

    [[ -e "$source" || -S "$source" ]] || return 0

    if [[ ! -d "$source" ]]; then
        mkdir -p "$(dirname "$target")"
        [[ -e "$target" || -S "$target" ]] || : >"$target"
    else
        mkdir -p "$target"
    fi

    if mountpoint -q "$target" 2>/dev/null; then
        return 0
    fi

    if mount "--$recursion" "$source" "$target" 2>/dev/null; then
        mount --make-rslave "$target" 2>/dev/null || true
        cleanup_add_mount "$target"
        return 0
    fi

    warn "$(t chroot_bind_failed "$source")"
    return 1
}

guest_hostname() {
    local root="$1"
    local file="$root/etc/hostname"
    local line name=""

    [[ -r "$file" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        line="${line%%#*}"
        read -r name _ <<< "$line" || true
        [[ -n "$name" ]] && break
    done < "$file"

    [[ -n "$name" ]] || return 1
    [[ ${#name} -le 64 && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    printf '%s' "$name"
}

# GNOME Shell talks to org.freedesktop.login1 and org.gnome.DisplayManager on
# the system bus. Neither systemd-logind nor GDM exists in a chroot, so a
# private guest bus would otherwise make the shell fail during startup. This
# tiny D-Bus service owns both names and answers the few calls GNOME makes,
# without going back to the host bus.
chroot_start_login1_stub() {
    local root="$1"
    local python_bin="" path stub_host_python=0
    local stub_host="$root/run/dbus/ved-login1-stub.py"
    local ready="$root/run/dbus/ved-login1-ready"
    local attempt

    for path in /usr/bin/python3 /bin/python3; do
        if [[ -x "$root$path" ]]; then
            python_bin="$path"
            break
        fi
    done
    if [[ -z "$python_bin" ]]; then
        # Some minimal guests have no Python. Running the same script from the
        # host is still safe: it only talks to the private socket under $root.
        python_bin="$(command -v python3 || true)"
        [[ -n "$python_bin" ]] || return 1
        stub_host_python=1
    else
        stub_host_python=0
    fi

    rm -f "$ready"
    cat > "$stub_host" <<'PY'
import os
import sys

LOGIN1_NAME = "org.freedesktop.login1"
LOGIN1_INTERFACE = "org.freedesktop.login1.Manager"
LOGIN1_PATH = "/org/freedesktop/login1"
DISPLAY_NAME = "org.gnome.DisplayManager"
DISPLAY_INTERFACE = "org.gnome.DisplayManager.Manager"
DISPLAY_PATH = "/org/gnome/DisplayManager/Manager"
DISPLAY_VERSION = "49.0"
READY = os.environ.get("VED_LOGIN1_READY", "/run/dbus/ved-login1-ready")
MACHINE_ID_FILE = os.environ.get("VED_LOGIN1_MACHINE_ID", "/etc/machine-id")

try:
    with open(MACHINE_ID_FILE, "r", encoding="ascii") as handle:
        MACHINE_ID = handle.read().strip()
except OSError:
    MACHINE_ID = ""


def mark_ready():
    try:
        with open(READY, "w", encoding="ascii") as handle:
            handle.write("ok\n")
    except OSError:
        pass


try:
    # Preferred: dbus-python is present on most Debian/Ubuntu desktops.
    import dbus
    import dbus.exceptions
    import dbus.service
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib

    DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    def own(name):
        try:
            return dbus.service.BusName(
                name, bus, allow_replacement=True, replace_existing=True)
        except dbus.exceptions.DBusException:
            return None

    login1_bus = own(LOGIN1_NAME)
    display_bus = own(DISPLAY_NAME)

    class Login1Stub(dbus.service.Object):
        def __init__(self, connection, object_path):
            dbus.service.Object.__init__(self, connection, object_path)

        @dbus.service.method(LOGIN1_INTERFACE, in_signature="", out_signature="s")
        def CanSuspend(self):
            return "no"

        @dbus.service.method(LOGIN1_INTERFACE, in_signature="", out_signature="s")
        def CanHibernate(self):
            return "no"

        @dbus.service.method(LOGIN1_INTERFACE, in_signature="", out_signature="s")
        def CanHybridSleep(self):
            return "no"

        @dbus.service.method(LOGIN1_INTERFACE, in_signature="", out_signature="s")
        def CanPowerOff(self):
            return "no"

        @dbus.service.method(LOGIN1_INTERFACE, in_signature="", out_signature="s")
        def CanReboot(self):
            return "no"

        @dbus.service.method("org.freedesktop.DBus.Peer",
                             in_signature="", out_signature="")
        def Ping(self):
            return None

        @dbus.service.method("org.freedesktop.DBus.Peer",
                             in_signature="", out_signature="s")
        def GetMachineId(self):
            return MACHINE_ID

        @dbus.service.method("org.freedesktop.DBus.Properties",
                             in_signature="s", out_signature="a{sv}")
        def GetAll(self, interface_name):
            return {}

    class DisplayManagerStub(dbus.service.Object):
        def __init__(self, connection, object_path):
            dbus.service.Object.__init__(self, connection, object_path)

        # GNOME Shell calls these with no arguments.
        @dbus.service.method(DISPLAY_INTERFACE,
                             in_signature="", out_signature="")
        def RegisterSession(self):
            return None

        @dbus.service.method(DISPLAY_INTERFACE,
                             in_signature="", out_signature="")
        def RegisterDisplay(self):
            return None

        @dbus.service.method("org.freedesktop.DBus.Properties",
                             in_signature="ss", out_signature="v")
        def Get(self, interface_name, property_name):
            if property_name == "Version":
                return dbus.String(DISPLAY_VERSION)
            raise dbus.exceptions.DBusException(
                "Unknown property " + property_name,
                name="org.freedesktop.DBus.Error.InvalidArgs")

    if login1_bus is not None:
        Login1Stub(login1_bus, LOGIN1_PATH)
    if display_bus is not None:
        DisplayManagerStub(display_bus, DISPLAY_PATH)
    mark_ready()
    GLib.MainLoop().run()

except ImportError:
    # Fallback for Fedora/Nobara: Gio/D-Bus via python3-gobject.
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib

    XML = """<node>
  <interface name="org.freedesktop.login1.Manager">
    <method name="CanSuspend"><arg type="s" direction="out"/></method>
    <method name="CanHibernate"><arg type="s" direction="out"/></method>
    <method name="CanHybridSleep"><arg type="s" direction="out"/></method>
    <method name="CanPowerOff"><arg type="s" direction="out"/></method>
    <method name="CanReboot"><arg type="s" direction="out"/></method>
  </interface>
  <interface name="org.gnome.DisplayManager.Manager">
    <method name="RegisterSession"/>
    <method name="RegisterDisplay"/>
    <property name="Version" type="s" access="read"/>
  </interface>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
    <method name="GetMachineId"><arg type="s" direction="out"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect"><arg type="s" direction="out"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
    <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
  </interface>
</node>"""

    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    def own(name):
        try:
            bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                          "org.freedesktop.DBus", "RequestName",
                          GLib.Variant("(su)", (name, 2)), None,
                          Gio.DBusCallFlags.NONE, -1, None)
        except GLib.Error:
            pass

    own(LOGIN1_NAME)
    own(DISPLAY_NAME)

    def on_method(connection, sender, path, interface_name,
                  method_name, parameters, invocation):
        if method_name == "Ping":
            invocation.return_value(None)
        elif method_name == "GetMachineId":
            invocation.return_value(GLib.Variant("(s)", (MACHINE_ID,)))
        elif method_name == "Introspect":
            invocation.return_value(GLib.Variant("(s)", (XML,)))
        elif method_name == "Get":
            values = parameters.unpack() if parameters is not None else ()
            property_name = values[1] if len(values) > 1 else ""
            if property_name == "Version":
                invocation.return_value(
                    GLib.Variant("(v)", (GLib.Variant("s", DISPLAY_VERSION),)))
            else:
                invocation.return_dbus_error(
                    "org.freedesktop.DBus.Error.InvalidArgs",
                    "Unknown property " + str(property_name))
        elif method_name == "GetAll":
            invocation.return_value(GLib.Variant("(a{sv})", ({},)))
        elif method_name in ("CanSuspend", "CanHibernate", "CanHybridSleep",
                             "CanPowerOff", "CanReboot"):
            invocation.return_value(GLib.Variant("(s)", ("no",)))
        elif method_name in ("RegisterSession", "RegisterDisplay"):
            invocation.return_value(None)
        else:
            invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.UnknownMethod",
                "No such method " + method_name)

    node = Gio.DBusNodeInfo.new_for_xml(XML)
    common = ("org.freedesktop.DBus.Peer",
              "org.freedesktop.DBus.Introspectable",
              "org.freedesktop.DBus.Properties")
    for object_path, wanted in (
            (LOGIN1_PATH, (LOGIN1_INTERFACE,) + common),
            (DISPLAY_PATH, (DISPLAY_INTERFACE,) + common)):
        for interface in node.interfaces:
            if interface.name in wanted:
                bus.register_object(object_path, interface, on_method, None, None)

    mark_ready()
    GLib.MainLoop().run()
PY
    chmod 755 "$stub_host" || return 1

    VED_GUEST_LOGIN1_STUB_PID=""
    if ((stub_host_python)); then
        DBUS_SYSTEM_BUS_ADDRESS="unix:path=$root/run/dbus/system_bus_socket" \
            VED_LOGIN1_READY="$ready" \
            VED_LOGIN1_MACHINE_ID="$root/etc/machine-id" \
            "$python_bin" "$stub_host" >/dev/null 2>&1 &
    else
        DBUS_SYSTEM_BUS_ADDRESS="unix:path=/run/dbus/system_bus_socket" \
            VED_LOGIN1_READY=/run/dbus/ved-login1-ready \
            VED_LOGIN1_MACHINE_ID=/etc/machine-id \
            chroot "$root" "$python_bin" /run/dbus/ved-login1-stub.py \
            >/dev/null 2>&1 &
    fi
    VED_GUEST_LOGIN1_STUB_PID=$!
    cleanup_add_pid "$VED_GUEST_LOGIN1_STUB_PID"

    for attempt in {1..30}; do
        [[ -e "$ready" ]] && return 0
        kill -0 "$VED_GUEST_LOGIN1_STUB_PID" 2>/dev/null || break
        sleep 0.1
    done

    kill "$VED_GUEST_LOGIN1_STUB_PID" 2>/dev/null || true
    wait "$VED_GUEST_LOGIN1_STUB_PID" 2>/dev/null || true
    VED_GUEST_LOGIN1_STUB_PID=""
    return 1
}

# Start the guest's own system bus. Sharing the host /run/dbus exposes
# org.freedesktop.hostname1 and friends, so a chroot desktop reports the host
# name and host desktop settings even after its UTS namespace is isolated.
chroot_start_system_bus() {
    local root="$1"
    local path dbus_bin="" broker_bin=""
    local attempt
    local -a bus_command=()

    for path in /usr/bin/dbus-daemon /bin/dbus-daemon; do
        if [[ -x "$root$path" ]]; then
            dbus_bin="$path"
            break
        fi
    done
    for path in /usr/bin/dbus-broker-launch /bin/dbus-broker-launch; do
        if [[ -x "$root$path" ]]; then
            broker_bin="$path"
            break
        fi
    done
    [[ -n "$dbus_bin" || -n "$broker_bin" ]] || return 1

    if [[ -n "$dbus_bin" ]]; then
        bus_command=(chroot "$root" "$dbus_bin" --system --nofork \
            --nopidfile --nosyslog \
            --address="unix:path=/run/dbus/system_bus_socket")
    else
        # Fedora/Nobara use dbus-broker. Its launcher reads the socket path
        # from the guest's system.conf, which points at our private /run/dbus.
        bus_command=(chroot "$root" "$broker_bin" --scope system \
            --config-file=/etc/dbus-1/system.conf)
    fi

    VED_GUEST_SYSTEM_BUS_PID=""
    "${bus_command[@]}" >/dev/null 2>&1 &
    VED_GUEST_SYSTEM_BUS_PID=$!
    cleanup_add_pid "$VED_GUEST_SYSTEM_BUS_PID"

    for attempt in {1..50}; do
        if [[ -S "$root/run/dbus/system_bus_socket" ]]; then
            if ! chroot_start_login1_stub "$root"; then
                warn "$(t login1_stub_failed)"
            fi
            return 0
        fi
        kill -0 "$VED_GUEST_SYSTEM_BUS_PID" 2>/dev/null || break
        sleep 0.1
    done

    kill "$VED_GUEST_SYSTEM_BUS_PID" 2>/dev/null || true
    wait "$VED_GUEST_SYSTEM_BUS_PID" 2>/dev/null || true
    VED_GUEST_SYSTEM_BUS_PID=""
    return 1
}

chroot_prepare_mounts() {
    local root="$1"
    local directory
    local guest_bus_dir=""

    for directory in dev proc sys; do
        chroot_bind "/$directory" "$root/$directory" rbind || true
    done

    if [[ "$VED_GRAPHICAL" -eq 1 && -n "${VED_HOST_RUNTIME_DIR:-}" &&
        -n "${VED_GUEST_RUNTIME:-}" ]]; then
        chroot_bind "$VED_HOST_RUNTIME_DIR" "$root$VED_GUEST_RUNTIME" rbind || true
    fi

    # A graphical chroot needs a system bus, but the host bus would leak the
    # host hostname/desktop identity. Give the guest a private /run/dbus and
    # start its own daemon there; non-graphical chroots keep the old behavior.
    if [[ "$VED_GRAPHICAL" -eq 1 && -n "${VED_RUN_DIR:-}" ]]; then
        guest_bus_dir="$VED_RUN_DIR/guest-dbus"
        if install -d -m 755 "$guest_bus_dir" 2>/dev/null; then
            cleanup_add_dir "$guest_bus_dir"
        else
            guest_bus_dir=""
        fi
    fi

    VED_GUEST_SYSTEM_BUS_ADDRESS=""
    if [[ -n "$guest_bus_dir" ]] &&
        chroot_bind "$guest_bus_dir" "$root/run/dbus" rbind; then
        if [[ "$VED_DRY_RUN" -eq 1 ]] || chroot_start_system_bus "$root"; then
            VED_GUEST_SYSTEM_BUS_ADDRESS="unix:path=/run/dbus/system_bus_socket"
        else
            warn "$(t guest_system_bus_failed)"
            umount "$root/run/dbus" 2>/dev/null || true
            if [[ -d /run/dbus ]]; then
                chroot_bind "/run/dbus" "$root/run/dbus" rbind || true
            fi
        fi
    elif [[ -d /run/dbus ]]; then
        chroot_bind "/run/dbus" "$root/run/dbus" rbind || true
    fi
    if [[ -d /run/systemd/resolve ]]; then
        chroot_bind "/run/systemd/resolve" "$root/run/systemd/resolve" rbind || true
    fi

    if [[ -d /tmp/.X11-unix ]]; then
        chroot_bind "/tmp/.X11-unix" "$root/tmp/.X11-unix" rbind || true
    fi

    if [[ -d /dev/dri ]]; then
        chroot_bind "/dev/dri" "$root/dev/dri" rbind || true
    fi
    if [[ -d /dev/snd ]]; then
        chroot_bind "/dev/snd" "$root/dev/snd" rbind || true
    fi
    if [[ -d /dev/input ]]; then
        chroot_bind "/dev/input" "$root/dev/input" rbind || true
    fi

    if [[ -f /etc/resolv.conf && -d "$root/etc" ]]; then
        if [[ ! -L "$root/etc/resolv.conf" ]]; then
            chroot_bind "/etc/resolv.conf" "$root/etc/resolv.conf" bind || true
        fi
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 && -n "${XAUTHORITY:-}" &&
        -f "${XAUTHORITY:-}" ]]; then
        if chroot_bind "$XAUTHORITY" "$root/tmp/.host-Xauthority" bind; then
            VED_GUEST_XAUTHORITY="/tmp/.host-Xauthority"
        fi
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 ]] &&
        prepare_guest_nonfips_config "$root" >/dev/null; then
        chroot_bind /dev/null "$root/etc/gcrypt/fips_enabled" bind || true
    fi
}

chroot_detect_user() {
    local root="$1"
    local user=""

    if [[ -n "$VED_USER" ]]; then
        printf '%s' "$VED_USER"
        return
    fi

    if ! session_is_graphical; then 
        printf 'root'
        return
    fi

    if [[ -r "$root/etc/passwd" ]]; then
        if [[ "$VED_GRAPHICAL" -eq 1 && -n "${VED_GUI_UID:-}" ]]; then
            user="$(awk -F: -v uid="$VED_GUI_UID" \
                '$3 == uid {print $1; exit}' "$root/etc/passwd")"
        fi
        if [[ -z "$user" ]]; then
            user="$(awk -F: '$3 == 1000 {print $1; exit}' "$root/etc/passwd")"
        fi
    fi

    printf '%s' "$user"
}

chroot_mark_time_synced() {
    local root="$1"
    local dir="$root/run/systemd/timesync"

    [[ "$VED_DRY_RUN" -eq 1 ]] && return 0
    [[ -x "$root/usr/lib/systemd/systemd" || -x "$root/lib/systemd/systemd" ]] ||
        return 0
    mkdir -p "$dir" || return 0
    cleanup_add_file "$dir/synchronized"
    (
        while :; do : >"$dir/synchronized"; sleep 1; done
    ) &
    cleanup_add_pid "$!"
}

chroot_apply_user_ids() {
    local root="$1"
    local user="$2"
    local uid=""
    local gid=""

    VED_GUEST_UID="${VED_GUI_UID:-}"
    VED_GUEST_GID="${VED_GUI_GID:-}"

    if [[ -n "$user" && -r "$root/etc/passwd" ]]; then
        uid="$(awk -F: -v u="$user" '$1 == u {print $3; exit}' "$root/etc/passwd")"
        gid="$(awk -F: -v u="$user" '$1 == u {print $4; exit}' "$root/etc/passwd")"
        [[ -n "$uid" ]] && VED_GUEST_UID="$uid"
        [[ -n "$gid" ]] && VED_GUEST_GID="$gid"
    fi

    if [[ "$VED_GUI_TARGET" != "nested" && -n "${VED_GUI_UID:-}" &&
        "$VED_GUEST_UID" != "$VED_GUI_UID" ]]; then
        warn "$(t guest_uid_mismatch "$VED_GUEST_UID" "$VED_GUI_UID")"
    fi
}

chroot_shell_for() {
    local root="$1"
    local user="$2"
    local shell=""

    if [[ -n "$user" && -r "$root/etc/passwd" ]]; then
        shell="$(awk -F: -v u="$user" '$1 == u {print $7; exit}' "$root/etc/passwd")"
    fi

    if [[ -z "$shell" || ! -x "$root$shell" ]]; then
        if [[ -x "$root/bin/bash" ]]; then
            shell="/bin/bash"
        else
            shell="/bin/sh"
        fi
    fi

    printf '%s' "$shell"
}

chroot_run() {
    local root="$1"
    local user="$2"
    local command="$3"
    local shell
    local user_spec="$user"
    local passwd_spec=""
    local env_bin="/usr/bin/env"
    local -a chroot_command=()
    local -a env_command=()
    local runtime="${VED_GUEST_RUNTIME:-}"
    local wayland_env=""
    local hostname_value=""
    local -a uts_command=()

    shell="$(chroot_shell_for "$root" "$user")"

    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        hostname_value="$(guest_hostname "$root" 2>/dev/null || true)"
        VED_GUEST_HOSTNAME="$hostname_value"
        if [[ -z "$hostname_value" ]]; then
            warn "$(t guest_hostname_missing)"
        fi
        if [[ "${VED_DRY_RUN:-0}" -eq 0 ]]; then
            raise_graphical_memlock_limit || true
        fi
    fi

    if [[ ! -x "$root/usr/bin/env" && -x "$root/bin/env" ]]; then
        env_bin="/bin/env"
    fi

    if [[ -n "$user" && "$user" != "root" && -r "$root/etc/passwd" ]]; then
        passwd_spec="$(awk -F: -v u="$user" '$1 == u {print $3 ":" $4; exit}' "$root/etc/passwd")"
        if [[ -n "$passwd_spec" ]]; then
            user_spec="$passwd_spec"
        fi
    fi

    chroot_command=(chroot)
    if [[ -n "$user" ]]; then
        chroot_command+=("--userspec=$user_spec")
    fi
    chroot_command+=("$root")

    env_command=(
        "$env_bin"
        "HOME=/root"
        "USER=root"
        "LOGNAME=root"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "TERM=${TERM:-xterm-256color}"
        "LANG=${LANG:-C.UTF-8}"
    )

    if [[ -n "$user" ]]; then
        env_command=(
            "$env_bin"
            "HOME=$(awk -F: -v u="$user" '$1 == u {print $6; exit}' "$root/etc/passwd" 2>/dev/null)"
            "USER=$user"
            "LOGNAME=$user"
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            "TERM=${TERM:-xterm-256color}"
            "LANG=${LANG:-C.UTF-8}"
        )
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 ]] && [[ -n "$runtime" ]]; then
        local guest_display
        guest_display="$(guest_display_value)"
        if [[ "${VED_WAYLAND_EXPORT_FAILED:-0}" -eq 1 ]]; then
            wayland_env=""
        else
            wayland_env="${VED_GUEST_WAYLAND_DISPLAY:-${WAYLAND_DISPLAY:-}}"
        fi
        env_command+=(
            "DISPLAY=$guest_display"
            "XDG_RUNTIME_DIR=$runtime"
            "XAUTHORITY=${VED_GUEST_XAUTHORITY:-${XAUTHORITY:-$VED_GUI_HOME/.Xauthority}}"
            "XDG_SESSION_DESKTOP=${VED_GUEST_SESSION_DESKTOP:-}"
            "XDG_CURRENT_DESKTOP=${VED_GUEST_CURRENT_DESKTOP:-}"
            "XDG_SESSION_CLASS=user"
            "XDG_VTNR=${XDG_VTNR:-}"
        )
        if [[ -n "$hostname_value" ]]; then
            env_command+=("HOSTNAME=$hostname_value")
        fi
        if [[ -n "${VED_GUEST_SYSTEM_BUS_ADDRESS:-}" ]]; then
            env_command+=("DBUS_SYSTEM_BUS_ADDRESS=$VED_GUEST_SYSTEM_BUS_ADDRESS")
        fi
        if [[ "$VED_GUI_TARGET" == "nested" ]]; then
            env_command+=(
                "WAYLAND_DISPLAY="
                "XDG_SESSION_TYPE=x11"
                "LIBGL_ALWAYS_SOFTWARE=1"
            )
        else
            env_command+=(
                "WAYLAND_DISPLAY=$wayland_env"
                "XDG_SESSION_TYPE=${VED_GUEST_SESSION_TYPE:-${VED_GUI_SESSION_TYPE:-${XDG_SESSION_TYPE:-wayland}}}"
            )
        fi
    fi

    if [[ -n "$command" ]]; then
        chroot_command+=("${env_command[@]}" /bin/sh -c "$command")
    else
        chroot_command+=("${env_command[@]}" "$shell")
    fi

    VED_UTS_NAMESPACE_OK=0
    if [[ -n "$hostname_value" ]] && have unshare && have hostname; then
        VED_UTS_NAMESPACE_OK=1
        uts_command=(
            unshare --uts /bin/sh -c
            'if ! hostname "$1" 2>/dev/null; then printf "%s\n" "$2" >&2; fi; shift 2; exec "$@"'
            sh
            "$hostname_value"
            "$(t guest_hostname_set_failed "$hostname_value")"
        )
    elif [[ "$VED_GRAPHICAL" -eq 1 && -n "$hostname_value" ]]; then
        warn "$(t uts_unshare_unavailable)"
    fi

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t dry_run)"
        if ((VED_UTS_NAMESPACE_OK)); then
            print_command "${uts_command[@]}" "${chroot_command[@]}"
        else
            print_command "${chroot_command[@]}"
        fi
        printf '\n'
        return 0
    fi

    # Verify the namespace is really available before exec'ing the desktop:
    # an EPERM here would otherwise abort the session entirely.
    if ((VED_UTS_NAMESPACE_OK)) && ! unshare --uts true 2>/dev/null; then
        warn "$(t uts_unshare_failed)"
        VED_UTS_NAMESPACE_OK=0
    fi

    if ((VED_UTS_NAMESPACE_OK)); then
        "${uts_command[@]}" "${chroot_command[@]}"
    else
        "${chroot_command[@]}"
    fi
}

backend_chroot() {
    local root="$VED_CHROOT_DIR"
    local user
    local command=""

    warn "$(t chroot_security_warning)"

    if [[ -n "$VED_ROOT_PARTITION" ]]; then
        [[ -b "$VED_ROOT_PARTITION" ]] ||
            die "$(t partition_missing "$VED_ROOT_PARTITION")"
        assert_unmounted "$VED_ROOT_PARTITION"
    else
        select_disk
        assert_unmounted "$VED_DISK"
        detect_root_partition
    fi

    select_session

    if [[ "$VED_SESSION" == "system" ]]; then
        if have systemd-nspawn; then
            info "$(t system_using_nspawn)"
            VED_BOOT=1
            backend_nspawn
            return
        fi
        die "$(t system_needs_nspawn)"
    fi

    if session_is_graphical; then
        VED_GRAPHICAL=1
    fi

    # fix: mount before the graphical questions to be able to inspect the guest
    info "$(t chroot_mounting)"
    mkdir -p "$root"
    cleanup_add_dir "$root"
    umount_path "$root"
    mount_linux_root "$VED_ROOT_PARTITION" "$root" "rw"
    info "$(t chroot_ready "$root")"

    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        detect_graphical_user
        session_probe_guest "$root"

        if session_is_graphical; then
            if [[ "$VED_SESSION" == "desktop" &&
                  -z "$VED_COMMAND" ]]; then
                select_desktop_session "$root" ||
                    die "$(t desktop_session_missing)"
            fi

            if [[ "$VED_SESSION" == "app" && -z "$VED_COMMAND" && -t 0 ]]; then
                VED_COMMAND="$(ask "$(t app_command_prompt)" "")"
            fi
            select_gui_target
            if [[ "$VED_GUI_TARGET" == "nested" ]]; then
                gui_start_nested || true
            fi
        fi
    fi

    show_configuration

    user="$(chroot_detect_user "$root")"
    if [[ -z "$user" ]]; then
        user="root"
        warn "$(t chroot_no_user)"
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        chroot_apply_user_ids "$root" "$user"
        prepare_graphical_runtime
    fi

    chroot_prepare_mounts "$root"

    chroot_mark_time_synced "$root" 

    if session_is_graphical; then
        command="$(session_build_command_ex "$root" || true)"
        if [[ -z "$command" ]]; then
            if [[ "$VED_SESSION" == "desktop" ]]; then
                warn "$(t desktop_session_missing)"
            else
                warn "$(t app_command_missing)"
            fi
            VED_SESSION="shell"
        fi
    fi

    if [[ -z "$command" ]]; then
        command="$VED_COMMAND"
    fi

    ensure_guest_desktop_identity "$command"

    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        info "$(t chroot_graphical)"
    fi

    if [[ -n "$command" ]]; then
        info "$(t chroot_command "$command")"
    else
        info "$(t chroot_entering "$user")"
        info "$(t chroot_shell)"
    fi

    chroot_run "$root" "$user" "$command"
}
