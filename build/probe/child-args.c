/*
 * Engine smoke test: SILICONCELLAR_CHILD_ARGS.
 *
 * The parent copies itself to probe-child.exe, sets
 * SILICONCELLAR_CHILD_ARGS=probe-child.exe=--sc-test and starts the copy
 * twice: once without the argument and once with it. Each time the child
 * command line must end with exactly one --sc-test.
 *
 * Exit code 0: both checks pass. Other exit codes: a check failed.
 */

#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#define CHILD_MARKER L"--child"
#define CHILD_ARGUMENT L"--sc-test"

static int child_main( const WCHAR *command_line )
{
    const WCHAR *first_argument = wcsstr( command_line, CHILD_ARGUMENT );
    size_t command_line_length = wcslen( command_line ), argument_length = wcslen( CHILD_ARGUMENT );

    if (!first_argument) return 2;
    if (wcsstr( first_argument + argument_length, CHILD_ARGUMENT )) return 3;
    if (command_line_length < argument_length ||
        wcscmp( command_line + command_line_length - argument_length, CHILD_ARGUMENT )) return 4;
    return 0;
}

static DWORD run_child( const WCHAR *child_path, const WCHAR *child_arguments )
{
    WCHAR command_line[MAX_PATH * 2];
    STARTUPINFOW startup_info = { sizeof(startup_info) };
    PROCESS_INFORMATION process_info;
    DWORD child_exit_code = 100;

    swprintf( command_line, ARRAYSIZE(command_line), L"\"%ls\" %ls", child_path, child_arguments );
    if (!CreateProcessW( child_path, command_line, NULL, NULL, FALSE, 0, NULL, NULL, &startup_info, &process_info ))
        return 101;
    WaitForSingleObject( process_info.hProcess, INFINITE );
    GetExitCodeProcess( process_info.hProcess, &child_exit_code );
    CloseHandle( process_info.hThread );
    CloseHandle( process_info.hProcess );
    return child_exit_code;
}

int main( void )
{
    const WCHAR *command_line = GetCommandLineW();
    WCHAR parent_path[MAX_PATH], child_path[MAX_PATH], *file_name;
    DWORD without_argument_result, with_argument_result;

    if (wcsstr( command_line, CHILD_MARKER )) return child_main( command_line );

    GetModuleFileNameW( NULL, parent_path, ARRAYSIZE(parent_path) );
    wcscpy( child_path, parent_path );
    if (!(file_name = wcsrchr( child_path, '\\' ))) return 102;
    wcscpy( file_name + 1, L"probe-child.exe" );
    if (!CopyFileW( parent_path, child_path, FALSE )) return 103;

    SetEnvironmentVariableW( L"SILICONCELLAR_CHILD_ARGS", L"other.exe=--wrong;PROBE-CHILD.EXE=" CHILD_ARGUMENT );
    without_argument_result = run_child( child_path, CHILD_MARKER );
    with_argument_result = run_child( child_path, CHILD_MARKER L" " CHILD_ARGUMENT );
    DeleteFileW( child_path );

    printf( "child-args: without argument %lu, with argument %lu\n", without_argument_result, with_argument_result );
    return without_argument_result || with_argument_result;
}
