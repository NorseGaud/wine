/*
 * Engine smoke test library for app-dll-path.exe.
 *
 * The build marks it as a Wine builtin DLL and puts it only in a temporary
 * folder, so Wine finds it only through an AppDefaults DllPath.
 */

__declspec(dllexport) int sc_probe_value( void )
{
    return 42;
}
