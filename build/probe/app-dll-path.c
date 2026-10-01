/*
 * Engine smoke test: HKCU\Software\Wine\AppDefaults\<app.exe>\SiliconCellar\DllPath.
 *
 * Usage: app-dll-path.exe <Unix folder that holds x86_64-windows/sc-app-dll-path.dll>
 *
 * The parent copies itself to probe-dll-child.exe and probe-dll-other.exe and
 * sets DllPath for probe-dll-child.exe only. probe-dll-child.exe must load
 * sc-app-dll-path.dll, and probe-dll-other.exe must not find it.
 *
 * Exit code 0: both checks pass. Other exit codes: a check failed.
 */

#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#define CHILD_MARKER L"--child"
#define EXPECT_LOADED L"expect-loaded"
#define EXPECT_MISSING L"expect-missing"
#define REGISTERED_CHILD L"probe-dll-child.exe"
#define OTHER_CHILD L"probe-dll-other.exe"

static int child_main( const WCHAR *command_line )
{
    HMODULE probe_library = LoadLibraryA( "sc-app-dll-path.dll" );
    int (*probe_value)( void );

    if (wcsstr( command_line, EXPECT_MISSING )) return probe_library ? 2 : 0;
    if (!probe_library) return 3;
    probe_value = (void *)GetProcAddress( probe_library, "sc_probe_value" );
    if (!probe_value) return 4;
    return probe_value() == 42 ? 0 : 5;
}

static DWORD run_child( const WCHAR *parent_path, const WCHAR *child_name, const WCHAR *expectation )
{
    WCHAR child_path[MAX_PATH], command_line[MAX_PATH * 2], *file_name;
    STARTUPINFOW startup_info = { sizeof(startup_info) };
    PROCESS_INFORMATION process_info;
    DWORD child_exit_code = 100;

    wcscpy( child_path, parent_path );
    if (!(file_name = wcsrchr( child_path, '\\' ))) return 101;
    wcscpy( file_name + 1, child_name );
    if (!CopyFileW( parent_path, child_path, FALSE )) return 102;

    swprintf( command_line, ARRAYSIZE(command_line), L"\"%ls\" %ls %ls", child_path, CHILD_MARKER, expectation );
    if (CreateProcessW( child_path, command_line, NULL, NULL, FALSE, 0, NULL, NULL, &startup_info, &process_info ))
    {
        WaitForSingleObject( process_info.hProcess, INFINITE );
        GetExitCodeProcess( process_info.hProcess, &child_exit_code );
        CloseHandle( process_info.hThread );
        CloseHandle( process_info.hProcess );
    }
    else child_exit_code = 103;
    DeleteFileW( child_path );
    return child_exit_code;
}

int wmain( int argc, WCHAR **argv )
{
    const WCHAR *command_line = GetCommandLineW();
    WCHAR parent_path[MAX_PATH];
    DWORD registered_result, other_result;
    LSTATUS status;

    if (wcsstr( command_line, CHILD_MARKER )) return child_main( command_line );
    if (argc < 2) return 104;

    status = RegSetKeyValueW( HKEY_CURRENT_USER, L"Software\\Wine\\AppDefaults\\" REGISTERED_CHILD L"\\SiliconCellar",
                              L"DllPath", REG_SZ, argv[1], (wcslen( argv[1] ) + 1) * sizeof(WCHAR) );
    if (status) return 105;

    GetModuleFileNameW( NULL, parent_path, ARRAYSIZE(parent_path) );
    registered_result = run_child( parent_path, REGISTERED_CHILD, EXPECT_LOADED );
    other_result = run_child( parent_path, OTHER_CHILD, EXPECT_MISSING );

    printf( "app-dll-path: registered app %lu, other app %lu\n", registered_result, other_result );
    return registered_result || other_result;
}
