// First-boot Steam-update splash, rendered by qmlscene6 (Qt6) as an
// OVERRIDE-REDIRECT fullscreen window.
//
// Why override-redirect: in Steam Game Mode gamescope runs with --steam
// (steamcompmgr). A plain managed X window (e.g. ffplay) maps but is NOT
// composited, because steamcompmgr only puts the *focus* window on the primary
// plane. gamescope exposes a dedicated `paint_override_redirect_plane`, so an
// override-redirect window IS composited. Qt's X11BypassWindowManagerHint maps
// to override-redirect on the xcb platform (the session is X11: DISPLAY=:0).
import QtQuick
import QtQuick.Window

Window {
    id: root
    x: 0
    y: 0
    width: 1920
    height: 1080
    visible: true
    color: "#171a21"
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.X11BypassWindowManagerHint

    Image {
        anchors.fill: parent
        source: "file:///usr/share/q8b/steam-splash.png"
        fillMode: Image.PreserveAspectFit
        smooth: true
    }
}
