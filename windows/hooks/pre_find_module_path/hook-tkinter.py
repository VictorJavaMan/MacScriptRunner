# The bundled Codex Python has a complete Tcl/Tk runtime, but PyInstaller's
# environment probe cannot recognize its relocated layout. Runtime paths and
# Tcl/Tk files are supplied explicitly by build-windows.ps1.
def pre_find_module_path(api):
    pass
