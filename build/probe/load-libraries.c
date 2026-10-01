/*
 * Engine smoke test: the libraries that Wine opens at run time.
 *
 * Wine opens these libraries by file name only (the SONAME_* values in
 * config.h), and dyld finds them through the rpath of the caller. This
 * host program is built with an rpath to <Engine>/lib and opens each
 * name in the same way, with all dependencies resolved at once.
 *
 * Usage: load-libraries <library file name>...
 * Exit code 0: every library loads. 1: one or more libraries did not load.
 */

#include <dlfcn.h>
#include <stdio.h>

int main( int argc, char **argv )
{
    int failed_count = 0;
    int i;

    for (i = 1; i < argc; i++)
    {
        if (dlopen( argv[i], RTLD_NOW )) printf( "loaded %s\n", argv[i] );
        else
        {
            printf( "FAILED %s: %s\n", argv[i], dlerror() );
            failed_count++;
        }
    }
    return failed_count ? 1 : 0;
}
