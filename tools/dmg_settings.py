# dmgbuild settings for awake. — run from the project folder:
#   python3 -m dmgbuild -s tools/dmg_settings.py -D app=build/awake.app "awake." dist/awake-X.dmg
import os.path

application = defines.get("app", "build/awake.app")  # noqa: F821 (provided by dmgbuild)
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"

background = "tools/dmg-background.tiff" if os.path.exists("tools/dmg-background.tiff") else "tools/dmg-background.png"
window_rect = ((240, 160), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {
    appname: (170, 190),
    "Applications": (470, 190),
}
