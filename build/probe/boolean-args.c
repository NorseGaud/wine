/*
 * Engine smoke test: BOOLEAN syscall arguments with dirty upper bits.
 *
 * Windows callers set only the low byte of a BOOLEAN. This probe passes
 * single_entry = TRUE and restart_scan = FALSE with all upper bits set.
 * If the Unix side reads the full register, restart_scan looks TRUE and
 * the enumeration of the object directory "\" never ends.
 *
 * Exit code 0: the enumeration ends. Exit code 1: it does not end or fails.
 */

#include <windows.h>
#include <winternl.h>
#include <stdio.h>

#define DIRTY_TRUE  ((ULONG_PTR)0xffffffffffffff01ull)
#define DIRTY_FALSE ((ULONG_PTR)0xffffffffffffff00ull)
#define MAX_ENTRIES 10000
#define STATUS_NO_MORE_ENTRIES_VALUE ((NTSTATUS)0x8000001a)
#ifndef DIRECTORY_QUERY
#define DIRECTORY_QUERY 0x0001
#endif

typedef NTSTATUS (WINAPI *open_directory_fn)( HANDLE *, ACCESS_MASK, OBJECT_ATTRIBUTES * );
typedef NTSTATUS (WINAPI *query_directory_dirty_fn)( HANDLE, void *, ULONG, ULONG_PTR, ULONG_PTR, ULONG *, ULONG * );

int main( void )
{
    HMODULE ntdll_module = GetModuleHandleW( L"ntdll.dll" );
    open_directory_fn open_directory = (open_directory_fn)GetProcAddress( ntdll_module, "NtOpenDirectoryObject" );
    query_directory_dirty_fn query_directory = (query_directory_dirty_fn)GetProcAddress( ntdll_module, "NtQueryDirectoryObject" );
    WCHAR root_name[] = L"\\";
    UNICODE_STRING root_name_string = { sizeof(root_name) - sizeof(WCHAR), sizeof(root_name), root_name };
    OBJECT_ATTRIBUTES root_attributes = { .Length = sizeof(root_attributes), .ObjectName = &root_name_string,
                                          .Attributes = OBJ_CASE_INSENSITIVE };
    BYTE entry_buffer[4096];
    ULONG enumeration_context = 0, returned_length, entry_count;
    HANDLE root_directory;
    NTSTATUS status;

    if (!open_directory || !query_directory)
    {
        printf( "boolean-args: ntdll exports not found\n" );
        return 1;
    }

    status = open_directory( &root_directory, DIRECTORY_QUERY, &root_attributes );
    if (status)
    {
        printf( "boolean-args: NtOpenDirectoryObject failed %#lx\n", status );
        return 1;
    }

    for (entry_count = 0; entry_count < MAX_ENTRIES; entry_count++)
    {
        status = query_directory( root_directory, entry_buffer, sizeof(entry_buffer), DIRTY_TRUE, DIRTY_FALSE,
                                  &enumeration_context, &returned_length );
        if (status == STATUS_NO_MORE_ENTRIES_VALUE) break;
        if (status)
        {
            printf( "boolean-args: NtQueryDirectoryObject failed %#lx\n", status );
            return 1;
        }
    }

    CloseHandle( root_directory );
    if (entry_count == MAX_ENTRIES)
    {
        printf( "boolean-args: enumeration did not end after %u entries\n", MAX_ENTRIES );
        return 1;
    }
    printf( "boolean-args: ok, %lu entries\n", entry_count );
    return 0;
}
